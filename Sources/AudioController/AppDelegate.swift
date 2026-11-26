import AppKit
import SwiftUI
import Combine

final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var panel: MiniPanel?
    private var hideTimer: Timer?
    private var monitors: [Any] = []
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private let panelSize = NSSize(width: 340, height: 250)

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.regular)   // shows in Dock, Cmd-Tab and Force Quit
        buildMainMenu()
        setupStatusItem()

        AppController.shared.pokeMiniPlayer = { [weak self] in self?.poke() }
        AppController.shared.start()
        HotkeyManager.shared.ensureRunning()
        VisualizerController.shared.start()
        installMonitors()

        Settings.shared.$data
            .map { $0.shortcutsEnabled }
            .removeDuplicates()
            .sink { [weak self] on in self?.statusItem.button?.alphaValue = on ? 1.0 : 0.4 }
            .store(in: &cancellables)

        openMainWindow()
    }

    // Closing the window keeps the app (and music) running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Clicking the Dock icon brings the full window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.player.savePosition()
        AppController.shared.library.saveState()
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            let img = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Audio Controller")
            img?.isTemplate = true
            b.image = img
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusClicked(_ sender: Any?) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || (e?.modifierFlags.contains(.control) ?? false) {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Audio Controller", action: #selector(openMainAction), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let show = NSMenuItem(title: "Show Mini-Player", action: #selector(showPanelAction), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let on = Settings.shared.data.shortcutsEnabled
        let sc = NSMenuItem(title: on ? "Disable All Shortcuts" : "Enable Shortcuts", action: #selector(toggleShortcuts), keyEquivalent: "")
        sc.target = self
        menu.addItem(sc)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Audio Controller", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showPanelAction() { showPanel() }
    @objc private func openMainAction() { openMainWindow() }
    @objc private func toggleShortcuts() { Settings.shared.data.shortcutsEnabled.toggle() }

    // MARK: Mini-player (shown ONLY by clicking the menu bar icon)

    private func togglePanel() {
        if panel?.isVisible == true { hideMiniPlayer() } else { showPanel() }
    }

    private func showPanel() {
        if panel == nil {
            let p = MiniPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.hasShadow = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hidesOnDeactivate = false
            p.acceptsMouseMovedEvents = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: MiniPlayerView())
            host.frame = NSRect(origin: .zero, size: panelSize)
            p.contentView = host
            panel = p
        }
        positionPanel()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        restartHideTimer()
    }

    private func positionPanel() {
        guard let button = statusItem.button, let bw = button.window else { return }
        let br = bw.frame
        var x = br.midX - panelSize.width / 2
        var y = br.minY - panelSize.height - 6
        if let scr = bw.screen ?? NSScreen.main {
            let v = scr.visibleFrame
            x = min(max(x, v.minX + 8), v.maxX - panelSize.width - 8)
            y = max(y, v.minY + 8)
        }
        panel?.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Closes the mini-player right away (X button, Esc, click elsewhere, or the status icon).
    func hideMiniPlayer() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
    }

    func quitApp() { NSApp.terminate(nil) }

    /// Resets the inactivity timer. Never shows the panel.
    private func poke() {
        guard panel?.isVisible == true else { return }
        restartHideTimer()
    }

    private func restartHideTimer() {
        hideTimer?.invalidate()
        let secs = max(3, Settings.shared.data.miniPlayerTimeout)
        let t = Timer(timeInterval: secs, repeats: false) { [weak self] _ in self?.hideMiniPlayer() }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    private func installMonitors() {
        let local: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel, .keyDown]
        if let m = NSEvent.addLocalMonitorForEvents(matching: local, handler: { [weak self] e in
            guard let self = self else { return e }
            guard let p = self.panel, p.isVisible else { return e }
            if e.type == .keyDown, e.keyCode == 53, e.window === p {          // Esc closes it
                self.hideMiniPlayer()
                return nil
            }
            if e.type == .leftMouseDown || e.type == .rightMouseDown {
                let statusWindow = self.statusItem.button?.window
                if e.window !== p && e.window !== statusWindow {              // click in our other windows
                    self.hideMiniPlayer()
                    return e
                }
            }
            self.activity()
            return e
        }) { monitors.append(m) }

        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel], handler: { [weak self] e in
            guard let self = self, let p = self.panel, p.isVisible else { return }
            if e.type == .leftMouseDown || e.type == .rightMouseDown {
                if !p.frame.contains(NSEvent.mouseLocation) { self.hideMiniPlayer() }   // click in another app
            } else {
                self.activity()
            }
        }) { monitors.append(g) }
    }

    private func activity() {
        guard let p = panel, p.isVisible else { return }
        if p.frame.contains(NSEvent.mouseLocation) { restartHideTimer() }
    }

    // MARK: Main window

    func openMainWindow() {
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Audio Controller"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.fullScreenPrimary]
            w.minSize = NSSize(width: 960, height: 600)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: MainView())
            w.center()
            w.setFrameAutosaveName("MainWindow")
            mainWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Audio Controller", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let view = NSMenu(title: "View")
        let fs = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fs)
        viewItem.submenu = view

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}
