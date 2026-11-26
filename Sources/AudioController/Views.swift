import SwiftUI
import AppKit

func fmtTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t)
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

let speedPresets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]

func speedLabel(_ s: Double) -> String {
    (s == s.rounded() ? String(Int(s)) : String(format: "%g", s)) + "x"
}

let accentRed = Color(red: 0.98, green: 0.26, blue: 0.36)

// MARK: - Mini player (menu bar)

struct MiniPlayerView: View {
    @ObservedObject var app = AppController.shared
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { app.mode }, set: { app.setMode($0) })) {
                    Text("Internal").tag(AppMode.internalPlayer)
                    Text("External").tag(AppMode.external)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button {
                    AppDelegate.shared?.openMainWindow()
                } label: { Image(systemName: "macwindow") }
                .buttonStyle(.plain)
                .help("Open the full app")
                Button {
                    AppDelegate.shared?.hideMiniPlayer()
                } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .help("Close mini-player")
                Button {
                    AppDelegate.shared?.quitApp()
                } label: { Image(systemName: "power") }
                .buttonStyle(.plain)
                .help("Quit Audio Controller")
            }
            if app.mode == .internalPlayer {
                InternalMiniView()
            } else {
                ExternalMiniView()
            }
        }
        .padding(14)
        .frame(width: 340, height: 250)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct InternalMiniView: View {
    @ObservedObject var player = AppController.shared.player
    @ObservedObject var settings = Settings.shared
    @State private var scrub: Double?

    var body: some View {
        let p = settings.activeProfile
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    if let img = player.artwork {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note").font(.title2).foregroundColor(.secondary)
                    }
                }
                .frame(width: 46, height: 46)
                .background(Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "Nothing playing").font(.headline).lineLimit(1)
                    Text(player.current?.artist ?? "Open the app to add music")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Text(fmtTime(scrub ?? player.position)).font(.caption.monospacedDigit())
                Slider(value: Binding(get: { scrub ?? player.position }, set: { scrub = $0 }),
                       in: 0...max(1, player.duration),
                       onEditingChanged: { editing in
                    if !editing, let s = scrub {
                        player.seek(to: s)
                        scrub = nil
                    }
                })
                Text(fmtTime(player.duration)).font(.caption.monospacedDigit())
            }
            HStack(spacing: 16) {
                Button { player.previous() } label: { Image(systemName: "backward.end.fill") }
                Button { player.seek(by: -p.seekBack) } label: { Image(systemName: "gobackward") }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                }
                Button { player.seek(by: p.seekForward) } label: { Image(systemName: "goforward") }
                Button { player.next() } label: { Image(systemName: "forward.end.fill") }
            }
            .buttonStyle(.plain)
            .font(.title3)
            HStack {
                Menu {
                    ForEach(speedPresets, id: \.self) { s in
                        Button(speedLabel(s)) { player.setRate(s) }
                    }
                } label: {
                    Text(speedLabel(player.rate))
                }
                .frame(width: 64)
                Image(systemName: "speaker.fill").font(.caption)
                Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...1)
            }
        }
    }
}

struct ExternalMiniView: View {
    @ObservedObject var ext = AppController.shared.external
    @ObservedObject var settings = Settings.shared

    var body: some View {
        let p = settings.activeProfile
        let caps = ext.selectedCapabilities
        VStack(spacing: 8) {
            if ext.sourceChoices.isEmpty {
                Spacer()
                Text("No app is playing audio right now.")
                    .font(.callout).foregroundColor(.secondary)
                Button("Send Play/Pause to system") { MediaKeys.send(.play) }
                Spacer()
            } else {
                Picker("Source", selection: Binding(get: { ext.selectedID ?? "" }, set: { ext.select($0) })) {
                    ForEach(ext.sourceChoices) { s in
                        Text(s.name + (s.playing ? "  ♪" : "  (idle)")).tag(s.id)
                    }
                }
                .labelsHidden()
                Text(ext.nowPlaying.isEmpty ? "—" : ext.nowPlaying)
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    CapChip(label: "Play", on: caps.playPause)
                    CapChip(label: "Seek", on: caps.seek)
                    CapChip(label: "Speed", on: caps.speed)
                    CapChip(label: "Info", on: caps.metadata)
                    if !caps.direct { CapChip(label: "System keys", on: true) }
                }
                HStack(spacing: 18) {
                    Button { ext.previous() } label: { Image(systemName: "backward.end.fill") }
                    Button { ext.seek(-p.seekBack) } label: { Image(systemName: "gobackward") }.disabled(!caps.seek)
                    Button { ext.playPause() } label: { Image(systemName: "playpause.circle.fill").font(.system(size: 34)) }
                    Button { ext.seek(p.seekForward) } label: { Image(systemName: "goforward") }.disabled(!caps.seek)
                    Button { ext.next() } label: { Image(systemName: "forward.end.fill") }
                }
                .buttonStyle(.plain)
                .font(.title3)
                HStack {
                    Menu {
                        ForEach(speedPresets, id: \.self) { s in
                            Button(speedLabel(s)) { ext.setSpeed(s) }
                        }
                    } label: {
                        Text(speedLabel(ext.speed))
                    }
                    .frame(width: 64)
                    .disabled(!caps.speed)
                    if !ext.statusNote.isEmpty {
                        Text(ext.statusNote).font(.caption2).foregroundColor(.orange).lineLimit(2)
                    }
                    Spacer()
                }
            }
        }
    }
}

struct CapChip: View {
    let label: String
    let on: Bool
    var body: some View {
        Text((on ? "✓ " : "✕ ") + label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(on ? Color.green.opacity(0.25) : Color.gray.opacity(0.25))
            .clipShape(Capsule())
    }
}
