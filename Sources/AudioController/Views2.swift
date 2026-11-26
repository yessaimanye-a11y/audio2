import SwiftUI
import AppKit

// MARK: - Equalizer

struct EqualizerView: View {
    @ObservedObject var player = AppController.shared.player
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("10-band equalizer").font(.title3)
                Spacer()
                Menu("Presets") {
                    ForEach(["Flat", "Bass Boost", "Treble Boost", "Vocal", "Loudness"], id: \.self) { n in
                        Button(n) { player.applyEQPreset(n) }
                    }
                }
                .frame(width: 100)
            }
            HStack(alignment: .bottom, spacing: 18) {
                ForEach(0..<10, id: \.self) { i in
                    VStack {
                        Text(String(format: "%+.0f", player.eqGains[i])).font(.caption.monospacedDigit())
                        Slider(value: Binding(get: { Double(player.eqGains[i]) },
                                              set: { player.setEQ(band: i, gain: Float($0)) }),
                               in: -12...12)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 150, height: 24)
                            .frame(width: 24, height: 150)
                        Text(Player.eqLabels[i]).font(.caption)
                    }
                }
            }
            .padding()
            Divider()
            Toggle("Audio normalization (reduce volume differences between tracks)",
                   isOn: Binding(get: { settings.data.normalize }, set: { player.setNormalize($0) }))
            Text("Bass and Treble are shelf filters; the middle bands are adjustable peaks. Applies to the internal player only.")
                .font(.caption).foregroundColor(.secondary)
            Spacer()
        }
        .padding()
    }
}

// MARK: - External audio

struct ExternalView: View {
    @ObservedObject var ext = AppController.shared.external
    @ObservedObject var settings = Settings.shared
    @ObservedObject var app = AppController.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Mode") {
                    Picker("", selection: Binding(get: { app.mode }, set: { app.setMode($0) })) {
                        Text("Internal Player").tag(AppMode.internalPlayer)
                        Text("External Control").tag(AppMode.external)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320)
                }

                GroupBox("Apps producing audio right now") {
                    VStack(alignment: .leading, spacing: 6) {
                        if ext.active.isEmpty {
                            Text("None detected. (Detection needs macOS 14.2 or newer.)").foregroundColor(.secondary)
                        }
                        ForEach(ext.active) { s in
                            HStack {
                                Image(systemName: ext.selectedID == s.bundleID ? "largecircle.fill.circle" : "circle")
                                Text(s.name)
                                Text(s.bundleID).font(.caption).foregroundColor(.secondary)
                                Spacer()
                                Button("Control this") { ext.select(s.bundleID); app.setMode(.external) }
                                Button("Make priority") {
                                    if !settings.data.priorityApps.contains(s.bundleID) {
                                        settings.data.priorityApps.append(s.bundleID)
                                    }
                                }
                            }
                        }
                    }
                }

                GroupBox("Automatic behavior") {
                    VStack(alignment: .leading) {
                        Toggle("Switch automatically to a newly active app (highest priority wins)",
                               isOn: $settings.data.autoSwitch)
                        Toggle("Pause the current app when another app starts playing",
                               isOn: $settings.data.autoPauseOthers)
                        Toggle("Resume the previous app when the new one stops",
                               isOn: $settings.data.autoResume)
                        Text("Auto-pause only works for apps we can control directly (Spotify, Music, VLC, Chrome, Safari, Brave, Edge).")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                GroupBox("Priority order (top = highest)") {
                    VStack(alignment: .leading) {
                        if settings.data.priorityApps.isEmpty {
                            Text("No priorities set.").foregroundColor(.secondary)
                        }
                        ForEach(Array(settings.data.priorityApps.enumerated()), id: \.element) { i, id in
                            HStack {
                                Text("\(i + 1). \(id)")
                                Spacer()
                                Button { move(i, -1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0)
                                Button { move(i, 1) } label: { Image(systemName: "arrow.down") }
                                    .disabled(i == settings.data.priorityApps.count - 1)
                                Button { settings.data.priorityApps.remove(at: i) } label: { Image(systemName: "trash") }
                            }
                        }
                    }
                }

                GroupBox("Remembered speed per app") {
                    VStack(alignment: .leading) {
                        if settings.data.appSpeeds.isEmpty {
                            Text("Set a speed while controlling a browser and it is remembered here.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        ForEach(settings.data.appSpeeds.keys.sorted(), id: \.self) { k in
                            HStack {
                                Text(k)
                                Spacer()
                                Text(speedLabel(settings.data.appSpeeds[k] ?? 1))
                                Button { settings.data.appSpeeds.removeValue(forKey: k) } label: { Image(systemName: "trash") }
                            }
                        }
                    }
                }

                GroupBox("What works for each app") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(ExternalMonitor.knownApps.enumerated()), id: \.offset) { _, a in
                            HStack(spacing: 8) {
                                Text(a.name).frame(width: 140, alignment: .leading)
                                CapChip(label: "Detect", on: true)
                                CapChip(label: "Play/Pause", on: a.caps.playPause)
                                CapChip(label: "Seek", on: a.caps.seek)
                                CapChip(label: "Speed", on: a.caps.speed)
                                CapChip(label: "Info", on: a.caps.metadata)
                            }
                        }
                        Text("Any other app: detection plus Play/Pause, Next and Previous through the system media keys (these go to the app macOS treats as 'Now Playing').")
                            .font(.caption).foregroundColor(.secondary)
                        Divider()
                        Text("Setup notes").font(.headline)
                        Text("• The first time you control Spotify, Music, VLC or a browser, macOS asks for Automation permission. Click OK.")
                        Text("• Chrome, Brave, Edge: menu View > Developer > Allow JavaScript from Apple Events.")
                        Text("• Safari: enable the Develop menu in Settings > Advanced, then Develop > Allow JavaScript from Apple Events.")
                        Text("• Firefox and Telegram expose no scripting, so only the system media keys work there.")
                        Text("• Browser control works on <video>/<audio> elements in all tabs; one tab at a time is paused/resumed together.")
                    }
                    .font(.caption)
                }
            }
            .padding()
        }
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard j >= 0, j < settings.data.priorityApps.count else { return }
        settings.data.priorityApps.swapAt(i, j)
    }
}

// MARK: - Shortcuts

struct RecorderButton: View {
    let action: ShortcutAction
    @ObservedObject var settings = Settings.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        let current = settings.activeProfile.bindings[action.rawValue]
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button(recording ? "Press keys… (Esc cancels)" : (current?.display ?? "Not set")) {
                    recording ? stop() : start()
                }
                .frame(minWidth: 170)
                Menu("Modifier only") {
                    Button("⌘ Command alone") { assign(Shortcut(keyCode: Shortcut.modifierOnlyCode, modifiers: Shortcut.command)) }
                    Button("⌥ Option alone") { assign(Shortcut(keyCode: Shortcut.modifierOnlyCode, modifiers: Shortcut.option)) }
                    Button("⌃ Control alone") { assign(Shortcut(keyCode: Shortcut.modifierOnlyCode, modifiers: Shortcut.control)) }
                    Button("⇧ Shift alone") { assign(Shortcut(keyCode: Shortcut.modifierOnlyCode, modifiers: Shortcut.shift)) }
                }
                .frame(width: 130)
                Button("Clear") { settings.setBinding(action, nil); message = nil }
            }
            if let m = message {
                Text(m).font(.caption).foregroundColor(.red)
            }
        }
    }

    private func start() {
        recording = true
        HotkeyManager.shared.recording = true
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            let mods = UInt(e.modifierFlags.rawValue) & Shortcut.modMask
            if e.keyCode == 53 && mods == 0 {
                stop()
                return nil
            }
            assign(Shortcut(keyCode: e.keyCode, modifiers: mods))
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        HotkeyManager.shared.recording = false
    }

    private func assign(_ s: Shortcut) {
        let r = settings.conflicts(s, for: action)
        if let b = r.blocking { message = b; return }
        settings.setBinding(action, s)
        message = r.warning
    }
}

struct ShortcutsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var hotkeys = HotkeyManager.shared
    @State private var newProfile = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Permission") {
                    VStack(alignment: .leading) {
                        HStack {
                            Image(systemName: hotkeys.active ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(hotkeys.active ? .green : .orange)
                            Text(hotkeys.active ? "Global shortcuts are active." : "Global shortcuts are OFF: grant permission, then they start automatically.")
                        }
                        Text("System Settings > Privacy & Security > Accessibility (and Input Monitoring if listed): turn on Audio Controller.")
                            .font(.caption).foregroundColor(.secondary)
                        HStack {
                            Button("Open Accessibility Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            Button("Open Input Monitoring Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                            }
                            Button("Retry") { HotkeyManager.shared.start(prompt: true) }
                        }
                    }
                }

                GroupBox("Profile") {
                    VStack(alignment: .leading) {
                        HStack {
                            Picker("Active profile", selection: Binding(
                                get: { settings.data.activeProfileID ?? UUID() },
                                set: { settings.data.activeProfileID = $0 })) {
                                ForEach(settings.data.profiles) { p in Text(p.name).tag(p.id) }
                            }
                            .frame(width: 280)
                            Button("Delete profile") { settings.deleteActiveProfile() }
                                .disabled(settings.data.profiles.count < 2)
                        }
                        HStack {
                            TextField("New profile name", text: $newProfile).frame(width: 200)
                            Button("Duplicate current as new profile") {
                                if !newProfile.isEmpty { settings.addProfile(named: newProfile); newProfile = "" }
                            }
                        }
                        HStack {
                            Stepper("Seek backward: \(Int(settings.activeProfile.seekBack)) s",
                                    value: Binding(get: { settings.activeProfile.seekBack },
                                                   set: { v in settings.updateActive { $0.seekBack = v } }),
                                    in: 1...120)
                            Stepper("Seek forward: \(Int(settings.activeProfile.seekForward)) s",
                                    value: Binding(get: { settings.activeProfile.seekForward },
                                                   set: { v in settings.updateActive { $0.seekForward = v } }),
                                    in: 1...120)
                        }
                        Toggle("Shortcuts enabled", isOn: $settings.data.shortcutsEnabled)
                    }
                }

                GroupBox("Shortcuts for this profile") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(ShortcutAction.allCases) { a in
                            HStack(alignment: .top) {
                                Text(a.title).frame(width: 300, alignment: .leading)
                                RecorderButton(action: a)
                            }
                        }
                        Text("Hold a seek shortcut down for continuous seeking. The emergency shortcut works even when the others are disabled.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                GroupBox("Apps where shortcuts are turned off") {
                    VStack(alignment: .leading) {
                        ForEach(settings.data.excludedApps, id: \.self) { id in
                            HStack {
                                Text(id)
                                Spacer()
                                Button { settings.data.excludedApps.removeAll { $0 == id } } label: { Image(systemName: "trash") }
                            }
                        }
                        Button("Add app…") { addExcluded() }
                        Text("While one of these apps is in front (a game, a text editor), shortcuts pass straight through to it.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
    }

    private func addExcluded() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
            if !settings.data.excludedApps.contains(id) { settings.data.excludedApps.append(id) }
        }
    }
}

