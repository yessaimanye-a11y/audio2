import Foundation
import AppKit
import CoreAudio

// MARK: - Capabilities

struct Capabilities {
    var playPause = false
    var seek = false
    var speed = false
    var metadata = false
    /// true = controls this specific app. false = only the system media key (goes to whatever app macOS considers "now playing").
    var direct = false
}

struct ActiveSource: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let pid: pid_t
    let since: Date
}

struct SourceChoice: Identifiable {
    let id: String
    let name: String
    let playing: Bool
}

// MARK: - Media keys

enum MediaKey: Int32 {
    case play = 16
    case next = 17
    case previous = 18
}

enum MediaKeys {
    static func send(_ key: MediaKey) {
        func post(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let state: Int32 = down ? 0xA : 0xB
            let data1 = Int((key.rawValue << 16) | (state << 8))
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }
}

// MARK: - AppleScript helper

enum AS {
    static var lastError: String?

    @discardableResult
    static func run(_ source: String) -> String? {
        var err: NSDictionary?
        guard let s = NSAppleScript(source: source) else { return nil }
        let r = s.executeAndReturnError(&err)
        if let e = err {
            lastError = (e.object(forKey: "NSAppleScriptErrorMessage") as? String) ?? "AppleScript error"
            return nil
        }
        lastError = nil
        return r.stringValue
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Controllers

protocol SourceController {
    var capabilities: Capabilities { get }
    func playPause()
    func pause()
    func resume()
    func seek(_ delta: Double)
    func setSpeed(_ rate: Double)
    func next()
    func previous()
    func metadata() -> String?
}

extension SourceController {
    func pause() { playPause() }
    func resume() { playPause() }
    func seek(_ delta: Double) {}
    func setSpeed(_ rate: Double) {}
    func next() { MediaKeys.send(.next) }
    func previous() { MediaKeys.send(.previous) }
    func metadata() -> String? { nil }
}

/// Fallback for any app (Telegram, Firefox, video players...): system media keys only.
struct MediaKeyController: SourceController {
    var capabilities: Capabilities { Capabilities(playPause: true, seek: false, speed: false, metadata: false, direct: false) }
    func playPause() { MediaKeys.send(.play) }
}

/// Spotify, Music and VLC through their AppleScript dictionaries.
struct AppleScriptPlayer: SourceController {
    enum Kind { case spotify, music, vlc }
    let bundleID: String
    let kind: Kind

    private var appName: String {
        switch kind {
        case .spotify: return "Spotify"
        case .music: return "Music"
        case .vlc: return "VLC"
        }
    }

    var capabilities: Capabilities { Capabilities(playPause: true, seek: true, speed: false, metadata: true, direct: true) }

    private func tell(_ body: String) -> String? {
        guard AS.isRunning(bundleID) else { return nil }
        return AS.run("tell application \"\(appName)\"\n\(body)\nend tell")
    }

    func playPause() {
        if kind == .vlc { _ = tell("play") } else { _ = tell("playpause") }
    }

    func pause() {
        if kind == .vlc { _ = tell("if playing then play") } else { _ = tell("pause") }
    }

    func resume() {
        if kind == .vlc { _ = tell("if not playing then play") } else { _ = tell("play") }
    }

    func seek(_ delta: Double) {
        if kind == .vlc {
            _ = tell("set current time to ((current time) + \(Int(delta.rounded())))")
        } else {
            _ = tell("set player position to ((player position) + \(delta))")
        }
    }

    func next() {
        if kind == .vlc { _ = tell("next") } else { _ = tell("next track") }
    }

    func previous() {
        if kind == .vlc { _ = tell("previous") } else { _ = tell("previous track") }
    }

    func metadata() -> String? {
        if kind == .vlc {
            return tell("return name of current item")
        }
        return tell("return (name of current track) & \" — \" & (artist of current track)")
    }
}

/// Browsers: runs JavaScript in every tab and acts on <video>/<audio> elements.
/// Needs: Chrome/Brave/Edge "View > Developer > Allow JavaScript from Apple Events", Safari "Develop > Allow JavaScript from Apple Events".
struct BrowserController: SourceController {
    enum Family { case chromium, safari }
    let bundleID: String
    let appName: String
    let family: Family

    var capabilities: Capabilities { Capabilities(playPause: true, seek: true, speed: true, metadata: true, direct: true) }

    private static let playing = "var m=Array.from(document.querySelectorAll('video,audio'));var p=m.filter(function(x){return !x.paused&&!x.ended});"

    private var jsToggle: String {
        "(function(){" + BrowserController.playing +
        "if(p.length){p.forEach(function(x){x.pause()});window.__acp=1;return 'paused'}" +
        "if(window.__acp){var q=m.find(function(x){return x.readyState>0});if(q){q.play();window.__acp=0;return 'playing'}}return ''})()"
    }

    private var jsPause: String {
        "(function(){" + BrowserController.playing +
        "if(p.length){p.forEach(function(x){x.pause()});window.__acp=1;return 'paused'}return ''})()"
    }

    private var jsResume: String {
        "(function(){" + BrowserController.playing +
        "if(!p.length&&window.__acp){var q=m.find(function(x){return x.readyState>0});if(q){q.play();window.__acp=0;return 'playing'}}return ''})()"
    }

    private func jsSeek(_ d: Double) -> String {
        "(function(){" + BrowserController.playing +
        "if(!p.length)return '';p.forEach(function(x){x.currentTime=Math.max(0,x.currentTime+(\(String(format: "%.2f", d))))});return 'ok'})()"
    }

    private func jsSpeed(_ r: Double) -> String {
        "(function(){" + BrowserController.playing +
        "if(!p.length)return '';p.forEach(function(x){x.playbackRate=\(String(format: "%.2f", r))});return 'ok'})()"
    }

    private var jsMeta: String {
        "(function(){" + BrowserController.playing +
        "if(!p.length)return '';var x=p[0];return document.title+' ['+Math.floor(x.currentTime)+'/'+Math.floor(x.duration||0)+'s @'+x.playbackRate+'x]'})()"
    }

    private func runJS(_ js: String) -> String {
        guard AS.isRunning(bundleID) else { return "" }
        let j = AS.escape(js)
        let call = family == .safari ? "do JavaScript \"\(j)\" in t" : "execute t javascript \"\(j)\""
        let script = """
        tell application "\(appName)"
          set out to {}
          repeat with w in windows
            repeat with t in tabs of w
              try
                set r to \(call)
                if r is not missing value then
                  if (r as text) is not "" then set end of out to (r as text)
                end if
              end try
            end repeat
          end repeat
          set AppleScript's text item delimiters to " | "
          return out as text
        end tell
        """
        return AS.run(script) ?? ""
    }

    func playPause() { _ = runJS(jsToggle) }
    func pause() { _ = runJS(jsPause) }
    func resume() { _ = runJS(jsResume) }
    func seek(_ delta: Double) { _ = runJS(jsSeek(delta)) }
    func setSpeed(_ rate: Double) { _ = runJS(jsSpeed(rate)) }

    func metadata() -> String? {
        let s = runJS(jsMeta)
        return s.isEmpty ? nil : s
    }
}

// MARK: - Detection (Core Audio process list, macOS 14.2+)

enum AudioDetector {
    static func normalize(_ raw: String) -> String {
        var id = raw
        if let r = id.range(of: ".helper", options: .caseInsensitive) { id = String(id[..<r.lowerBound]) }
        if id.hasPrefix("com.apple.WebKit") { return "com.apple.Safari" }
        if id.hasPrefix("org.mozilla") { return "org.mozilla.firefox" }
        return id
    }

    static func activeApps() -> [(bundleID: String, pid: pid_t)] {
        guard #available(macOS 14.2, *) else { return [] }
        return activeAppsModern()
    }

    @available(macOS 14.2, *)
    private static func readU32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        return value
    }

    @available(macOS 14.2, *)
    private static func activeAppsModern() -> [(bundleID: String, pid: pid_t)] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        var result: [(bundleID: String, pid: pid_t)] = []
        var seen = Set<String>()
        for obj in ids {
            guard readU32(obj, kAudioProcessPropertyIsRunningOutput) == 1 else { continue }
            let pid = pid_t(bitPattern: readU32(obj, kAudioProcessPropertyPID))

            var bundle = ""
            var ba = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
            var cf: Unmanaged<CFString>?
            var bs = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(obj, &ba, 0, nil, &bs, &cf) == noErr, let c = cf {
                bundle = c.takeRetainedValue() as String
            }
            if bundle.isEmpty, let app = NSRunningApplication(processIdentifier: pid), let b = app.bundleIdentifier {
                bundle = b
            }
            guard !bundle.isEmpty else { continue }
            let id = normalize(bundle)
            if id == Bundle.main.bundleIdentifier { continue }
            if seen.insert(id).inserted { result.append((id, pid)) }
        }
        return result
    }
}

// MARK: - Monitor

final class ExternalMonitor: ObservableObject {
    @Published var active: [ActiveSource] = []
    @Published var selectedID: String?
    @Published var nowPlaying: String = ""
    @Published var speed: Double = 1
    @Published var statusNote: String = ""

    private var timer: Timer?
    private var firstPoll = true
    private var pollCount = 0
    private var pausedBySwitch: [String] = []
    private var triggerID: String?
    private var knownNames: [String: String] = [:]

    static let knownApps: [(id: String, name: String, caps: Capabilities)] = [
        ("com.spotify.client", "Spotify", Capabilities(playPause: true, seek: true, speed: false, metadata: true, direct: true)),
        ("com.apple.Music", "Music", Capabilities(playPause: true, seek: true, speed: false, metadata: true, direct: true)),
        ("org.videolan.vlc", "VLC", Capabilities(playPause: true, seek: true, speed: false, metadata: true, direct: true)),
        ("com.google.Chrome", "Google Chrome", Capabilities(playPause: true, seek: true, speed: true, metadata: true, direct: true)),
        ("com.apple.Safari", "Safari", Capabilities(playPause: true, seek: true, speed: true, metadata: true, direct: true)),
        ("com.brave.Browser", "Brave", Capabilities(playPause: true, seek: true, speed: true, metadata: true, direct: true)),
        ("com.microsoft.edgemac", "Microsoft Edge", Capabilities(playPause: true, seek: true, speed: true, metadata: true, direct: true)),
        ("org.mozilla.firefox", "Firefox", Capabilities(playPause: true, seek: false, speed: false, metadata: false, direct: false)),
        ("ru.keepcoder.Telegram", "Telegram", Capabilities(playPause: true, seek: false, speed: false, metadata: false, direct: false)),
        ("org.telegram.desktop", "Telegram Desktop", Capabilities(playPause: true, seek: false, speed: false, metadata: false, direct: false))
    ]

    func controller(for id: String) -> SourceController {
        switch id {
        case "com.spotify.client": return AppleScriptPlayer(bundleID: id, kind: .spotify)
        case "com.apple.Music": return AppleScriptPlayer(bundleID: id, kind: .music)
        case "org.videolan.vlc": return AppleScriptPlayer(bundleID: id, kind: .vlc)
        case "com.google.Chrome": return BrowserController(bundleID: id, appName: "Google Chrome", family: .chromium)
        case "com.brave.Browser": return BrowserController(bundleID: id, appName: "Brave Browser", family: .chromium)
        case "com.microsoft.edgemac": return BrowserController(bundleID: id, appName: "Microsoft Edge", family: .chromium)
        case "com.apple.Safari": return BrowserController(bundleID: id, appName: "Safari", family: .safari)
        default: return MediaKeyController()
        }
    }

    var selectedCapabilities: Capabilities {
        guard let id = selectedID else { return Capabilities(playPause: true) }
        return controller(for: id).capabilities
    }

    var selectedName: String {
        guard let id = selectedID else { return "audio source" }
        return knownNames[id] ?? id
    }

    var sourceChoices: [SourceChoice] {
        var list = active.map { SourceChoice(id: $0.bundleID, name: $0.name, playing: true) }
        if let id = selectedID, !list.contains(where: { $0.id == id }) {
            list.append(SourceChoice(id: id, name: knownNames[id] ?? id, playing: false))
        }
        return list
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func select(_ id: String) {
        guard !id.isEmpty else { return }
        selectedID = id
        speed = Settings.shared.data.appSpeeds[id] ?? 1
        nowPlaying = ""
        statusNote = ""
    }

    private func displayName(_ id: String) -> String {
        if let k = ExternalMonitor.knownApps.first(where: { $0.id == id }) { return k.name }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? id
    }

    private func priorityRank(_ id: String) -> Int {
        Settings.shared.data.priorityApps.firstIndex(of: id) ?? Int.max
    }

    private func poll() {
        pollCount += 1
        let settings = Settings.shared.data
        var fresh: [ActiveSource] = []
        for f in AudioDetector.activeApps() {
            let since = active.first { $0.bundleID == f.bundleID }?.since ?? Date()
            let name = displayName(f.bundleID)
            knownNames[f.bundleID] = name
            fresh.append(ActiveSource(bundleID: f.bundleID, name: name, pid: f.pid, since: since))
        }
        let started = fresh.filter { n in !active.contains { $0.bundleID == n.bundleID } }
        let wasFirst = firstPoll
        firstPoll = false

        if !wasFirst, !started.isEmpty {
            let trigger = started.sorted { priorityRank($0.bundleID) < priorityRank($1.bundleID) }.first!
            if settings.autoSwitch {
                if selectedID == nil || priorityRank(trigger.bundleID) <= priorityRank(selectedID ?? "") {
                    select(trigger.bundleID)
                }
            }
            if settings.autoPauseOthers {
                triggerID = trigger.bundleID
                for o in fresh where o.bundleID != trigger.bundleID {
                    let c = controller(for: o.bundleID)
                    if c.capabilities.direct {
                        c.pause()
                        pausedBySwitch.append(o.bundleID)
                    }
                }
            }
            for s in started {
                if let saved = settings.appSpeeds[s.bundleID], controller(for: s.bundleID).capabilities.speed {
                    controller(for: s.bundleID).setSpeed(saved)
                }
            }
        }

        if let t = triggerID, !fresh.contains(where: { $0.bundleID == t }) {
            if settings.autoResume {
                for id in pausedBySwitch { controller(for: id).resume() }
            }
            pausedBySwitch.removeAll()
            triggerID = nil
        }

        if active != fresh { active = fresh }

        if selectedID == nil, !fresh.isEmpty {
            let best = fresh.sorted { priorityRank($0.bundleID) < priorityRank($1.bundleID) }.first!
            select(best.bundleID)
        }

        if AppController.shared.mode == .external, let id = selectedID {
            let c = controller(for: id)
            let isBrowser = c is BrowserController
            if c.capabilities.metadata, !isBrowser || pollCount % 3 == 0 {
                nowPlaying = c.metadata() ?? ""
                if nowPlaying.isEmpty, isBrowser, let e = AS.lastError, e.lowercased().contains("javascript") {
                    statusNote = "Enable “Allow JavaScript from Apple Events” in the browser's Developer/Develop menu."
                }
            }
        }
    }

    // MARK: Commands

    private func current() -> SourceController? {
        guard let id = selectedID else { return nil }
        return controller(for: id)
    }

    func playPause() {
        if let c = current() { c.playPause() } else { MediaKeys.send(.play) }
    }

    func seek(_ delta: Double) {
        guard let c = current() else { return }
        if c.capabilities.seek { c.seek(delta); statusNote = "" }
        else { statusNote = "\(selectedName) doesn't support seeking from here." }
    }

    func setSpeed(_ r: Double) {
        guard let id = selectedID, let c = current() else { return }
        guard c.capabilities.speed else { statusNote = "\(selectedName) doesn't support speed control from here."; return }
        let v = min(4, max(0.25, r))
        c.setSpeed(v)
        speed = v
        Settings.shared.data.appSpeeds[id] = v
        statusNote = ""
    }

    func toggleSpeed() { setSpeed(abs(speed - 1) < 0.001 ? 2 : 1) }
    func stepSpeed(_ d: Double) { setSpeed(speed + d) }

    func next() {
        if let c = current() { c.next() } else { MediaKeys.send(.next) }
    }

    func previous() {
        if let c = current() { c.previous() } else { MediaKeys.send(.previous) }
    }
}
