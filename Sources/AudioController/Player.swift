import Foundation
import AVFoundation
import AppKit

struct LyricLine: Identifiable {
    let id = UUID()
    let time: Double
    let text: String
}

enum RepeatMode: String, CaseIterable {
    case off, all, one
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

final class Player: ObservableObject {
    let library: Library
    let settings: Settings

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)

    private var file: AVAudioFile?
    private var sampleRate: Double = 44100
    private var seekFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var timer: Timer?
    private var tickCount = 0
    private var lastTapPush = Date.distantPast

    static let eqFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let eqLabels = ["Bass", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "Treble"]

    @Published var current: Track?
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Double = 1
    @Published var volume: Double = 0.8
    @Published var queue: [Track] = []
    @Published var context: [Track] = []
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var abA: Double?
    @Published var abB: Double?
    @Published var sleepAt: Date?
    @Published var lyrics: [LyricLine] = []
    @Published var artwork: NSImage?
    @Published var eqGains: [Float] = Array(repeating: 0, count: 10)
    @Published var errorMessage: String?

    /// Audio levels for the visualizer (not @Published on purpose, read by a timer).
    var levels: [Float] = Array(repeating: 0, count: 96)

    init(library: Library, settings: Settings) {
        self.library = library
        self.settings = settings

        engine.attach(node)
        engine.attach(timePitch)
        engine.attach(eq)

        rate = settings.data.lastSpeed
        timePitch.rate = Float(rate)
        volume = settings.data.volume
        engine.mainMixerNode.outputVolume = Float(volume)
        shuffle = settings.data.shuffle
        repeatMode = RepeatMode(rawValue: settings.data.repeatMode) ?? .off
        eqGains = settings.data.eqGains
        configureEQ()

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            self?.processTap(buffer)
        }

        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigChange()
        }

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Loading and playback

    func play(_ track: Track, in list: [Track]? = nil, startAt: Double = 0, autoplay: Bool = true) {
        if let list = list { context = list }
        guard FileManager.default.fileExists(atPath: track.path) else {
            errorMessage = "File not found: \(track.title)"
            return
        }
        do {
            let f = try AVAudioFile(forReading: track.url)
            generation += 1
            node.stop()
            engine.stop()
            file = f
            let fmt = f.processingFormat
            sampleRate = fmt.sampleRate
            engine.connect(node, to: timePitch, format: fmt)
            engine.connect(timePitch, to: eq, format: fmt)
            engine.connect(eq, to: engine.mainMixerNode, format: fmt)
            engine.prepare()
            try engine.start()

            duration = Double(f.length) / fmt.sampleRate
            current = track
            errorMessage = nil
            abA = nil
            abB = nil
            let start = max(0, min(startAt, max(0, duration - 0.5)))
            schedule(from: AVAudioFramePosition(start * fmt.sampleRate), play: autoplay)
            isPlaying = autoplay
            position = start
            if autoplay { library.noteStarted(track) } else { library.lastTrackID = track.id; library.saveState() }
            loadExtras(for: track)
            applyNormalization(for: track)
        } catch {
            errorMessage = "Can't play “\(track.title)”: \(error.localizedDescription)"
        }
    }

    private func schedule(from frame: AVAudioFramePosition, play: Bool) {
        guard let f = file else { return }
        generation += 1
        let gen = generation
        node.stop()
        seekFrame = max(0, min(frame, f.length))
        let remaining = f.length - seekFrame
        guard remaining > 0 else {
            DispatchQueue.main.async { [weak self] in self?.handleFinished() }
            return
        }
        node.scheduleSegment(f, startingFrame: seekFrame, frameCount: AVAudioFrameCount(remaining), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen else { return }
                self.handleFinished()
            }
        }
        if play {
            if !engine.isRunning { try? engine.start() }
            node.play()
        }
    }

    private func handleFinished() {
        if let c = current { library.setPosition(c.id, 0) }
        if repeatMode == .one, let c = current {
            play(c)
        } else {
            next(auto: true)
        }
    }

    private func handleConfigChange() {
        guard file != nil else { return }
        let t = isPlaying ? liveTime() : position
        let was = isPlaying
        try? engine.start()
        schedule(from: AVAudioFramePosition(t * sampleRate), play: was)
    }

    func togglePlay() { isPlaying ? pause() : resume() }

    func pause() {
        guard isPlaying else { return }
        position = liveTime()
        node.pause()
        isPlaying = false
        savePosition()
    }

    func resume() {
        if current == nil { startFromContext(); return }
        if !engine.isRunning { try? engine.start() }
        node.play()
        isPlaying = true
    }

    func startFromContext() {
        if let t = queue.first {
            queue.removeFirst()
            play(t)
        } else if let t = context.first ?? library.tracks.first {
            if context.isEmpty { context = library.tracks }
            play(t)
        }
    }

    func seek(to time: Double) {
        guard file != nil else { return }
        let t = max(0, min(time, duration))
        schedule(from: AVAudioFramePosition(t * sampleRate), play: isPlaying)
        position = t
    }

    func seek(by delta: Double) {
        guard file != nil else { return }
        seek(to: (isPlaying ? liveTime() : position) + delta)
    }

    func next(auto: Bool = false) {
        if !queue.isEmpty {
            let t = queue.removeFirst()
            play(t)
            return
        }
        guard !context.isEmpty else { stopAtEnd(); return }
        if shuffle {
            var pool = context
            if let c = current, pool.count > 1 { pool.removeAll { $0.id == c.id } }
            if let t = pool.randomElement() { play(t) }
            return
        }
        let idx = context.firstIndex { $0.id == current?.id } ?? -1
        let n = idx + 1
        if n < context.count {
            play(context[n])
        } else if repeatMode == .all || !auto {
            play(context[0])
        } else {
            stopAtEnd()
        }
    }

    func previous() {
        if position > 3 || context.isEmpty { seek(to: 0); return }
        let idx = context.firstIndex { $0.id == current?.id } ?? 0
        if idx > 0 {
            play(context[idx - 1])
        } else if repeatMode == .all {
            play(context[context.count - 1])
        } else {
            seek(to: 0)
        }
    }

    private func stopAtEnd() {
        isPlaying = false
        position = 0
        schedule(from: 0, play: false)
        if let c = current { library.setPosition(c.id, 0) }
    }

    func restoreLastSession() {
        guard let id = library.lastTrackID, let t = library.track(id) else { return }
        context = library.tracks
        play(t, startAt: library.positions[id.uuidString] ?? 0, autoplay: false)
    }

    func savePosition() {
        guard let c = current else { return }
        library.setPosition(c.id, isPlaying ? liveTime() : position)
    }

    private func liveTime() -> Double {
        guard file != nil else { return 0 }
        if let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt), pt.sampleTime >= 0 {
            let t = (Double(seekFrame) + Double(pt.sampleTime)) / sampleRate
            return min(max(0, t), duration)
        }
        return position
    }

    // MARK: - Speed, volume, modes

    func setRate(_ r: Double) {
        let v = min(8, max(0.25, r))
        rate = v
        timePitch.rate = Float(v)
        settings.data.lastSpeed = v
    }

    func toggleSpeed() { setRate(abs(rate - 1) < 0.001 ? 2 : 1) }

    func setVolume(_ v: Double) {
        volume = min(1, max(0, v))
        engine.mainMixerNode.outputVolume = Float(volume)
        settings.data.volume = volume
    }

    func toggleShuffle() {
        shuffle.toggle()
        settings.data.shuffle = shuffle
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        settings.data.repeatMode = repeatMode.rawValue
    }

    // MARK: - Queue

    func enqueue(_ t: Track) { queue.append(t) }
    func enqueueNext(_ t: Track) { queue.insert(t, at: 0) }
    func clearQueue() { queue.removeAll() }

    // MARK: - A-B repeat

    func setA() { abA = isPlaying ? liveTime() : position }
    func setB() {
        let t = isPlaying ? liveTime() : position
        if let a = abA, t <= a { return }
        abB = t
    }
    func clearAB() { abA = nil; abB = nil }

    // MARK: - Sleep timer

    func setSleep(minutes: Double) { sleepAt = Date().addingTimeInterval(minutes * 60) }

    func setSleep(at date: Date) {
        var d = date
        if d <= Date() { d = d.addingTimeInterval(86400) }
        sleepAt = d
    }

    func cancelSleep() { sleepAt = nil }

    // MARK: - Equalizer

    private func configureEQ() {
        for (i, b) in eq.bands.enumerated() {
            b.filterType = i == 0 ? .lowShelf : (i == 9 ? .highShelf : .parametric)
            b.frequency = Player.eqFrequencies[i]
            b.bandwidth = 1.0
            b.gain = eqGains[i]
            b.bypass = false
        }
    }

    func setEQ(band: Int, gain: Float) {
        guard band >= 0, band < 10 else { return }
        eq.bands[band].gain = gain
        eqGains[band] = gain
        settings.data.eqGains = eqGains
    }

    func applyEQPreset(_ name: String) {
        let presets: [String: [Float]] = [
            "Flat": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            "Bass Boost": [8, 6, 4, 2, 0, 0, 0, 0, 0, 0],
            "Treble Boost": [0, 0, 0, 0, 0, 1, 3, 5, 6, 8],
            "Vocal": [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1],
            "Loudness": [6, 4, 1, 0, -1, -1, 0, 2, 4, 5]
        ]
        guard let g = presets[name] else { return }
        for i in 0..<10 { setEQ(band: i, gain: g[i]) }
    }

    // MARK: - Normalization

    func setNormalize(_ on: Bool) {
        settings.data.normalize = on
        if let c = current { applyNormalization(for: c) }
    }

    private func applyNormalization(for track: Track) {
        node.volume = 1
        guard settings.data.normalize else { return }
        let url = track.url
        let id = track.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let g = Player.loudnessGain(url: url)
            DispatchQueue.main.async {
                guard let self = self, self.current?.id == id else { return }
                self.node.volume = g
            }
        }
    }

    private static func loudnessGain(url: URL) -> Float {
        guard let f = try? AVAudioFile(forReading: url) else { return 1 }
        let want = min(f.length, Int64(f.processingFormat.sampleRate * 30))
        guard want > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(want)) else { return 1 }
        do { try f.read(into: buf, frameCount: AVAudioFrameCount(want)) } catch { return 1 }
        guard let ch = buf.floatChannelData else { return 1 }
        let n = Int(buf.frameLength)
        let channels = Int(buf.format.channelCount)
        guard n > 0, channels > 0 else { return 1 }
        var sum: Double = 0
        for c in 0..<channels {
            let p = ch[c]
            for i in 0..<n { let v = Double(p[i]); sum += v * v }
        }
        let rms = sqrt(sum / Double(n * channels))
        if rms < 0.0001 { return 1 }
        return Float(min(2.0, max(0.25, 0.1 / rms)))
    }

    // MARK: - Lyrics / artwork

    private func loadExtras(for track: Track) {
        lyrics = []
        artwork = nil
        let base = track.url.deletingPathExtension()
        for ext in ["lrc", "LRC"] {
            let u = base.appendingPathExtension(ext)
            if let s = try? String(contentsOf: u, encoding: .utf8) {
                lyrics = Player.parseLRC(s)
                break
            }
        }
        let id = track.id
        Task {
            let img = await ArtworkCache.shared.image(for: track)
            await MainActor.run {
                if self.current?.id == id { self.artwork = img }
            }
        }
    }

    static func parseLRC(_ text: String) -> [LyricLine] {
        guard let re = try? NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{1,2}(?:\\.\\d{1,3})?)\\]") else { return [] }
        var out: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let ms = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = ms.last else { continue }
            let lyric = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in ms {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                out.append(LyricLine(time: mm * 60 + ss, text: lyric))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    // MARK: - Visualizer levels

    private func processTap(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let bins = 96
        var out = [Float](repeating: 0, count: bins)
        let per = max(1, n / bins)
        for b in 0..<bins {
            let start = b * per
            let end = min(n, start + per)
            if start >= end { continue }
            var s: Float = 0
            for i in start..<end { s += ch[i] * ch[i] }
            out[b] = min(1, sqrtf(s / Float(end - start)) * 3)
        }
        DispatchQueue.main.async { [weak self] in self?.pushLevels(out) }
    }

    private func pushLevels(_ new: [Float]) {
        for i in 0..<min(levels.count, new.count) {
            levels[i] = max(new[i], levels[i] * 0.8)
        }
    }

    func decayLevels() {
        for i in 0..<levels.count { levels[i] *= 0.85; if levels[i] < 0.005 { levels[i] = 0 } }
    }

    // MARK: - Timer

    private func tick() {
        tickCount += 1
        if isPlaying {
            let t = liveTime()
            if let b = abB, t >= b {
                seek(to: abA ?? 0)
                return
            }
            if abs(t - position) >= 0.25 { position = t }
            if tickCount % 50 == 0, let c = current { library.setPosition(c.id, t) }
        }
        if let s = sleepAt, Date() >= s {
            sleepAt = nil
            pause()
        }
    }
}
