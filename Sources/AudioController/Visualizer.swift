import Foundation
import AppKit
import Combine

final class EdgeView: NSView {
    enum Edge { case top, bottom, left, right }

    let edge: Edge
    var levels: [Float] = []
    var color: NSColor = .cyan
    var style: String = "bars"
    var rainbow = true
    var barWidth: CGFloat = 2

    private var palette: [NSColor] = []
    private var paletteKey = ""

    init(frame: NSRect, edge: Edge) {
        self.edge = edge
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isOpaque: Bool { false }

    private func makePalette(count: Int) {
        let key = "\(count)|\(rainbow)|\(color.hexString)"
        if key == paletteKey { return }
        paletteKey = key
        var p: [NSColor] = []
        p.reserveCapacity(count)
        for i in 0..<count {
            if rainbow {
                let hue = CGFloat(i) / CGFloat(max(1, count)) * 0.82
                p.append(NSColor(calibratedHue: hue, saturation: 0.85, brightness: 1.0, alpha: 1))
            } else {
                p.append(color)
            }
        }
        palette = p
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        bounds.fill(using: .copy)
        guard !levels.isEmpty else { return }

        let horizontal = (edge == .top || edge == .bottom)
        let length = horizontal ? bounds.width : bounds.height
        let thick = horizontal ? bounds.height : bounds.width
        let n = levels.count

        if style == "glow" {
            let avg = CGFloat(levels.reduce(0, +)) / CGFloat(n)
            color.withAlphaComponent(min(0.85, avg * 1.6)).setFill()
            bounds.fill(using: .sourceOver)
            return
        }

        let bw = max(1, barWidth)
        let pitch = bw * 2
        let count = max(1, Int(length / pitch))
        makePalette(count: count)

        for i in 0..<count {
            let f = n > 1 ? CGFloat(i) / CGFloat(max(1, count - 1)) * CGFloat(n - 1) : 0
            let i0 = min(n - 1, Int(f))
            let i1 = min(n - 1, i0 + 1)
            let t = f - CGFloat(i0)
            let lv = CGFloat(levels[i0]) * (1 - t) + CGFloat(levels[i1]) * t
            let h = max(1, lv * thick)
            let pos = CGFloat(i) * pitch
            var r: NSRect
            switch edge {
            case .top: r = NSRect(x: pos, y: bounds.maxY - h, width: bw, height: h)
            case .bottom: r = NSRect(x: pos, y: bounds.minY, width: bw, height: h)
            case .left: r = NSRect(x: bounds.minX, y: pos, width: h, height: bw)
            case .right: r = NSRect(x: bounds.maxX - h, y: pos, width: h, height: bw)
            }
            palette[i].setFill()
            r.fill()
        }
    }
}

final class VisualizerController {
    static let shared = VisualizerController()

    private var windows: [NSWindow] = []
    private var views: [EdgeView] = []
    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var signature = ""
    private var wasActive = false

    func start() {
        cancellable = Settings.shared.$data
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsChanged() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.signature = ""
            self?.settingsChanged()
        }
        settingsChanged()
    }

    private func settingsChanged() {
        let d = Settings.shared.data
        let sig = "\(d.visualizerEnabled)|\(d.visualizerThickness)|\(d.visualizerEdges)"
        if sig != signature {
            signature = sig
            rebuild()
        }
    }

    private func rebuild() {
        timer?.invalidate()
        timer = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()

        let d = Settings.shared.data
        guard d.visualizerEnabled else { return }
        let t = CGFloat(d.visualizerThickness)

        for screen in NSScreen.screens {
            let f = screen.frame
            let defs: [(EdgeView.Edge, NSRect, Bool)] = [
                (.top, NSRect(x: f.minX, y: f.maxY - t, width: f.width, height: t), d.visualizerEdges[0]),
                (.bottom, NSRect(x: f.minX, y: f.minY, width: f.width, height: t), d.visualizerEdges[1]),
                (.left, NSRect(x: f.minX, y: f.minY, width: t, height: f.height), d.visualizerEdges[2]),
                (.right, NSRect(x: f.maxX - t, y: f.minY, width: t, height: f.height), d.visualizerEdges[3])
            ]
            for (edge, rect, on) in defs where on {
                let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
                w.isOpaque = false
                w.backgroundColor = .clear
                w.hasShadow = false
                w.ignoresMouseEvents = true
                w.isReleasedWhenClosed = false
                w.level = .statusBar
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                let v = EdgeView(frame: NSRect(origin: .zero, size: rect.size), edge: edge)
                w.contentView = v
                w.orderFrontRegardless()
                windows.append(w)
                views.append(v)
            }
        }

        let tm = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    private func tick() {
        let player = AppController.shared.player
        if !player.isPlaying { player.decayLevels() }
        let lv = player.levels
        let activeNow = lv.contains { $0 > 0.01 }
        guard activeNow || wasActive else { return }
        wasActive = activeNow
        let d = Settings.shared.data
        let color = NSColor(hex: d.visualizerColor)
        for v in views {
            v.levels = lv
            v.style = d.visualizerStyle
            v.color = color
            v.rainbow = d.visualizerRainbow
            v.barWidth = CGFloat(d.visualizerBarWidth)
            v.needsDisplay = true
        }
    }
}
