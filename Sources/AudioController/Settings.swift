import Foundation
import AppKit
import SwiftUI

// MARK: - Shortcuts

struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt

    static let modifierOnlyCode: UInt16 = 0xFFFF
    static let control: UInt = 0x40000
    static let option: UInt = 0x80000
    static let shift: UInt = 0x20000
    static let command: UInt = 0x100000
    static let modMask: UInt = control | option | shift | command

    var isModifierOnly: Bool { keyCode == Shortcut.modifierOnlyCode }

    var display: String {
        var s = ""
        if modifiers & Shortcut.control != 0 { s += "⌃" }
        if modifiers & Shortcut.option != 0 { s += "⌥" }
        if modifiers & Shortcut.shift != 0 { s += "⇧" }
        if modifiers & Shortcut.command != 0 { s += "⌘" }
        if isModifierOnly { return s + " (alone)" }
        return s + (KeyNames.map[keyCode] ?? "Key\(keyCode)")
    }
}

enum KeyNames {
    static let map: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}

enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case playPause, seekBack, seekForward, toggleSpeed, speedUp, speedDown
    case nextTrack, previousTrack, emergencyDisable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .seekBack: return "Seek backward"
        case .seekForward: return "Seek forward"
        case .toggleSpeed: return "Toggle 1x / 2x speed"
        case .speedUp: return "Increase speed"
        case .speedDown: return "Decrease speed"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .emergencyDisable: return "EMERGENCY: disable / enable all shortcuts"
        }
    }
}

struct ShortcutProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var seekBack: Double = 5
    var seekForward: Double = 5
    var bindings: [String: Shortcut]

    static func defaultBindings() -> [String: Shortcut] {
        let co = Shortcut.control | Shortcut.option
        let cos = co | Shortcut.shift
        return [
            ShortcutAction.playPause.rawValue: Shortcut(keyCode: 49, modifiers: co),
            ShortcutAction.seekBack.rawValue: Shortcut(keyCode: 123, modifiers: co),
            ShortcutAction.seekForward.rawValue: Shortcut(keyCode: 124, modifiers: co),
            ShortcutAction.toggleSpeed.rawValue: Shortcut(keyCode: 126, modifiers: co),
            ShortcutAction.speedUp.rawValue: Shortcut(keyCode: 24, modifiers: co),
            ShortcutAction.speedDown.rawValue: Shortcut(keyCode: 27, modifiers: co),
            ShortcutAction.nextTrack.rawValue: Shortcut(keyCode: 124, modifiers: cos),
            ShortcutAction.previousTrack.rawValue: Shortcut(keyCode: 123, modifiers: cos),
            ShortcutAction.emergencyDisable.rawValue: Shortcut(keyCode: 53, modifiers: cos)
        ]
    }

    static func defaults() -> [ShortcutProfile] {
        [
            ShortcutProfile(name: "General Use", seekBack: 5, seekForward: 5, bindings: defaultBindings()),
            ShortcutProfile(name: "Studying", seekBack: 10, seekForward: 10, bindings: defaultBindings()),
            ShortcutProfile(name: "Music", seekBack: 5, seekForward: 15, bindings: defaultBindings())
        ]
    }
}

// MARK: - Settings

struct SettingsData: Codable {
    var profiles: [ShortcutProfile] = ShortcutProfile.defaults()
    var activeProfileID: UUID? = nil
    var shortcutsEnabled: Bool = true
    var lastSpeed: Double = 1.0
    var appSpeeds: [String: Double] = [:]
    var excludedApps: [String] = []
    var priorityApps: [String] = []
    var autoSwitch: Bool = false
    var autoPauseOthers: Bool = false
    var autoResume: Bool = false
    var miniPlayerTimeout: Double = 15
    var volume: Double = 0.8
    var normalize: Bool = true
    var eqGains: [Float] = Array(repeating: 0, count: 10)
    var shuffle: Bool = false
    var repeatMode: String = "off"
    var visualizerEnabled: Bool = false
    var visualizerStyle: String = "bars"
    var visualizerColor: String = "#33CCFF"
    var visualizerThickness: Double = 40
    var visualizerEdges: [Bool] = [true, true, true, true]
    var visualizerRainbow: Bool = true
    var visualizerBarWidth: Double = 2
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let key = "settings.v2"

    @Published var data: SettingsData {
        didSet { save() }
    }

    private init() {
        var loaded = SettingsData()
        if let d = UserDefaults.standard.data(forKey: "settings.v2"),
           let s = try? JSONDecoder().decode(SettingsData.self, from: d) {
            loaded = s
        }
        if loaded.profiles.isEmpty { loaded.profiles = ShortcutProfile.defaults() }
        if loaded.activeProfileID == nil || !loaded.profiles.contains(where: { $0.id == loaded.activeProfileID }) {
            loaded.activeProfileID = loaded.profiles[0].id
        }
        if loaded.eqGains.count != 10 { loaded.eqGains = Array(repeating: 0, count: 10) }
        if loaded.visualizerEdges.count != 4 { loaded.visualizerEdges = [true, true, true, true] }
        data = loaded
    }

    private func save() {
        if let d = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    var activeProfile: ShortcutProfile {
        data.profiles.first { $0.id == data.activeProfileID } ?? data.profiles[0]
    }

    func updateActive(_ change: (inout ShortcutProfile) -> Void) {
        guard let idx = data.profiles.firstIndex(where: { $0.id == data.activeProfileID }) else { return }
        var p = data.profiles[idx]
        change(&p)
        data.profiles[idx] = p
    }

    func setBinding(_ action: ShortcutAction, _ shortcut: Shortcut?) {
        updateActive { p in
            if let s = shortcut {
                p.bindings[action.rawValue] = s
            } else {
                p.bindings.removeValue(forKey: action.rawValue)
            }
        }
    }

    func addProfile(named name: String) {
        let base = activeProfile
        let p = ShortcutProfile(name: name, seekBack: base.seekBack, seekForward: base.seekForward, bindings: base.bindings)
        data.profiles.append(p)
        data.activeProfileID = p.id
    }

    func deleteActiveProfile() {
        guard data.profiles.count > 1 else { return }
        data.profiles.removeAll { $0.id == data.activeProfileID }
        data.activeProfileID = data.profiles[0].id
    }

    private static let reserved: [(UInt16, UInt, String)] = [
        (8, Shortcut.command, "Copy"), (9, Shortcut.command, "Paste"), (7, Shortcut.command, "Cut"),
        (6, Shortcut.command, "Undo"), (0, Shortcut.command, "Select All"), (12, Shortcut.command, "Quit"),
        (13, Shortcut.command, "Close Window"), (48, Shortcut.command, "App Switcher"),
        (49, Shortcut.command, "Spotlight"), (4, Shortcut.command, "Hide App"), (46, Shortcut.command, "Minimize"),
        (1, Shortcut.command, "Save"), (3, Shortcut.command, "Find")
    ]

    /// blocking: the same key is already used by another action in this profile (not saved).
    /// warning: saved, but may interfere with normal typing or a macOS shortcut.
    func conflicts(_ s: Shortcut, for action: ShortcutAction) -> (blocking: String?, warning: String?) {
        for (key, other) in activeProfile.bindings where other == s && key != action.rawValue {
            let name = ShortcutAction(rawValue: key)?.title ?? key
            return ("\(s.display) is already used for “\(name)”.", nil)
        }
        if !s.isModifierOnly {
            if let hit = Settings.reserved.first(where: { $0.0 == s.keyCode && $0.1 == s.modifiers }) {
                return (nil, "\(s.display) is also the macOS shortcut for “\(hit.2)”. It will be blocked everywhere.")
            }
            if s.modifiers == 0 {
                return (nil, "A plain key will be blocked in every app (you could not type it). Add apps to the exception list or use a modifier.")
            }
        } else {
            return (nil, "Modifier-only shortcuts fire when you tap the key alone. They can trigger by accident when you click while holding it.")
        }
        return (nil, nil)
    }
}

// MARK: - Color helpers

extension NSColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count != 6 { h = "33CCFF" }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#33CCFF" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
