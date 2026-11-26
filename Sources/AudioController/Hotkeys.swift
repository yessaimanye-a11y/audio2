import Foundation
import AppKit
import ApplicationServices

private func hotkeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    return HotkeyManager.shared.handle(type: type, event: event)
}

final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published var active = false
    var recording = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private var frontBundleID = ""
    private var modCandidate: UInt?
    private var lastFlags: UInt = 0

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.frontBundleID = app.bundleIdentifier ?? ""
            }
        }
        frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func ensureRunning() {
        _ = start(prompt: true)
        retryTimer?.invalidate()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.tap == nil { _ = self.start(prompt: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    @discardableResult
    func start(prompt: Bool) -> Bool {
        if tap != nil { return true }
        if prompt {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        var mask: CGEventMask = 0
        for t in types { mask |= (1 << CGEventMask(t.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: hotkeyCallback,
                                        userInfo: nil) else {
            active = false
            return false
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        active = true
        return true
    }

    private func excluded() -> Bool {
        Settings.shared.data.excludedApps.contains(frontBundleID)
    }

    private func fire(_ action: ShortcutAction) {
        DispatchQueue.main.async { AppController.shared.perform(action) }
    }

    private func match(code: UInt16, flags: UInt) -> ShortcutAction? {
        let p = Settings.shared.activeProfile
        for (key, s) in p.bindings where s.keyCode == code && s.modifiers == flags {
            return ShortcutAction(rawValue: key)
        }
        return nil
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        if recording { return pass }

        let settings = Settings.shared
        let flags = UInt(event.flags.rawValue) & Shortcut.modMask

        switch type {
        case .leftMouseDown, .rightMouseDown:
            modCandidate = nil
            return pass

        case .flagsChanged:
            if lastFlags == 0 && flags != 0 && flags.nonzeroBitCount == 1 {
                modCandidate = flags
            } else if flags == 0 {
                if let c = modCandidate {
                    let p = settings.activeProfile
                    for (key, s) in p.bindings where s.isModifierOnly && s.modifiers == c {
                        if let a = ShortcutAction(rawValue: key) {
                            if a == .emergencyDisable || (settings.data.shortcutsEnabled && !excluded()) { fire(a) }
                        }
                    }
                }
                modCandidate = nil
            } else if flags.nonzeroBitCount > 1 {
                modCandidate = nil
            }
            lastFlags = flags
            return pass

        case .keyDown:
            modCandidate = nil
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            guard let action = match(code: code, flags: flags) else { return pass }
            if action != .emergencyDisable {
                guard settings.data.shortcutsEnabled, !excluded() else { return pass }
            }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat && !(action == .seekBack || action == .seekForward) { return nil }
            fire(action)
            return nil

        default:
            return pass
        }
    }
}
