import Foundation
import AppKit

enum AppMode: String {
    case internalPlayer = "Internal Player"
    case external = "External Control"
}

final class AppController: ObservableObject {
    static let shared = AppController()

    let settings = Settings.shared
    let library: Library
    let player: Player
    let external = ExternalMonitor()

    @Published var mode: AppMode = .internalPlayer
    var pokeMiniPlayer: (() -> Void)?

    private init() {
        let lib = Library()
        library = lib
        player = Player(library: lib, settings: Settings.shared)
    }

    func start() {
        player.restoreLastSession()
        external.start()
        library.startAutoScan()
    }

    func setMode(_ m: AppMode) {
        if m == .external { player.pause() }
        mode = m
        pokeMiniPlayer?()
    }

    func playInternal(_ track: Track, in list: [Track]) {
        mode = .internalPlayer
        player.play(track, in: list)
    }

    func perform(_ action: ShortcutAction) {
        if action == .emergencyDisable {
            settings.data.shortcutsEnabled.toggle()
            NSSound.beep()
            return
        }
        pokeMiniPlayer?()
        let p = settings.activeProfile
        if mode == .internalPlayer {
            switch action {
            case .playPause: player.togglePlay()
            case .seekBack: player.seek(by: -p.seekBack)
            case .seekForward: player.seek(by: p.seekForward)
            case .toggleSpeed: player.toggleSpeed()
            case .speedUp: player.setRate(player.rate + 0.25)
            case .speedDown: player.setRate(player.rate - 0.25)
            case .nextTrack: player.next()
            case .previousTrack: player.previous()
            case .emergencyDisable: break
            }
        } else {
            switch action {
            case .playPause: external.playPause()
            case .seekBack: external.seek(-p.seekBack)
            case .seekForward: external.seek(p.seekForward)
            case .toggleSpeed: external.toggleSpeed()
            case .speedUp: external.stepSpeed(0.25)
            case .speedDown: external.stepSpeed(-0.25)
            case .nextTrack: external.next()
            case .previousTrack: external.previous()
            case .emergencyDisable: break
            }
        }
    }
}
