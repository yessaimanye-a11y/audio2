import Foundation
import AVFoundation
import AppKit

struct Track: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var added: Date = Date()

    var url: URL { URL(fileURLWithPath: path) }
    var albumKey: String { album + "|" + artist }
}

struct Playlist: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var trackIDs: [UUID] = []
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var trackID: UUID
    var time: Double
    var label: String
}

struct AlbumGroup: Identifiable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]
}

struct ArtistGroup: Identifiable {
    let id: String
    let name: String
    let tracks: [Track]
}

private struct LibraryData: Codable {
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    var bookmarks: [Bookmark] = []
    var watched: [String] = []
}

final class Library: ObservableObject {
    @Published var tracks: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var bookmarks: [Bookmark] = []
    @Published var history: [UUID] = []
    @Published var watchedFolders: [String] = []
    @Published var albums: [AlbumGroup] = []
    @Published var artists: [ArtistGroup] = []
    @Published var importing = false
    @Published var scanningMac = false
    @Published var statusText = ""

    var positions: [String: Double] = [:]
    var lastTrackID: UUID?

    static let supportedExtensions: Set<String> = ["mp3", "wav", "flac", "aac", "m4a", "m4b", "aiff", "aif", "caf", "alac", "mp4"]

    private let fileURL: URL
    private var query: NSMetadataQuery?
    private var scanTimer: Timer?
    private var lastScan = Date.distantPast

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioController", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library-v2.json")

        if let d = try? Data(contentsOf: fileURL),
           let s = try? JSONDecoder().decode(LibraryData.self, from: d) {
            tracks = s.tracks
            playlists = s.playlists
            bookmarks = s.bookmarks
            watchedFolders = s.watched
        }
        let ud = UserDefaults.standard
        positions = (ud.dictionary(forKey: "positions") as? [String: Double]) ?? [:]
        history = (ud.stringArray(forKey: "history") ?? []).compactMap { UUID(uuidString: $0) }
        if let s = ud.string(forKey: "lastTrack") { lastTrackID = UUID(uuidString: s) }
        rebuildGroups()
    }

    // MARK: Persistence

    func save() {
        let s = LibraryData(tracks: tracks, playlists: playlists, bookmarks: bookmarks, watched: watchedFolders)
        if let d = try? JSONEncoder().encode(s) {
            try? d.write(to: fileURL, options: .atomic)
        }
    }

    func saveState() {
        let ud = UserDefaults.standard
        ud.set(positions, forKey: "positions")
        ud.set(history.map { $0.uuidString }, forKey: "history")
        ud.set(lastTrackID?.uuidString, forKey: "lastTrack")
    }

    // MARK: Lookup and grouping

    func track(_ id: UUID) -> Track? { tracks.first { $0.id == id } }

    func tracks(in playlist: Playlist) -> [Track] {
        playlist.trackIDs.compactMap { track($0) }
    }

    var historyTracks: [Track] { history.compactMap { track($0) } }

    func rebuildGroups() {
        var byAlbum: [String: [Track]] = [:]
        var byArtist: [String: [Track]] = [:]
        for t in tracks {
            byAlbum[t.albumKey, default: []].append(t)
            byArtist[t.artist, default: []].append(t)
        }
        var a: [AlbumGroup] = []
        for (k, v) in byAlbum {
            let sorted = v.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            a.append(AlbumGroup(id: k, title: v[0].album, artist: v[0].artist, tracks: sorted))
        }
        a.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        albums = a

        var b: [ArtistGroup] = []
        for (k, v) in byArtist {
            let sorted = v.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            b.append(ArtistGroup(id: k, name: k, tracks: sorted))
        }
        b.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        artists = b
    }

    // MARK: Import and automatic scanning

    static func collectFiles(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                if let en = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let f as URL in en {
                        if supportedExtensions.contains(f.pathExtension.lowercased()) { files.append(f) }
                    }
                }
            } else if supportedExtensions.contains(u.pathExtension.lowercased()) {
                files.append(u)
            }
        }
        return files
    }

    /// Adds files or folders. Folders you add are remembered ("watched") and re-scanned automatically.
    func importURLs(_ urls: [URL], watch: Bool = true) {
        if watch {
            let fm = FileManager.default
            for u in urls {
                var d: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &d), d.boolValue, !watchedFolders.contains(u.path) {
                    watchedFolders.append(u.path)
                }
            }
            save()
        }
        importing = true
        Task {
            let files = await Task.detached(priority: .utility) { Library.collectFiles(urls) }.value
            let existing = await MainActor.run { Set(self.tracks.map { $0.path }) }
            var added: [Track] = []
            for f in files where !existing.contains(f.path) {
                added.append(await Library.makeTrack(f))
            }
            await MainActor.run {
                let have = Set(self.tracks.map { $0.path })
                let fresh = added.filter { !have.contains($0.path) }
                if !fresh.isEmpty {
                    self.tracks.append(contentsOf: fresh)
                    self.tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    self.rebuildGroups()
                    self.save()
                    self.statusText = "Added \(fresh.count) new track\(fresh.count == 1 ? "" : "s")"
                }
                self.importing = false
            }
        }
    }

    static func makeTrack(_ url: URL) async -> Track {
        let meta = await MetadataReader.read(url: url)
        return Track(path: url.path,
                     title: meta.title ?? url.deletingPathExtension().lastPathComponent,
                     artist: meta.artist ?? "Unknown Artist",
                     album: meta.album ?? "Unknown Album",
                     duration: meta.duration)
    }

    /// Re-reads title/artist/album (and clears cached artwork) for every track.
    func refreshMetadata() {
        importing = true
        ArtworkCache.shared.forget()
        let snapshot = tracks
        Task {
            var updated: [Track] = []
            for t in snapshot {
                let m = await MetadataReader.read(url: t.url)
                var n = t
                n.title = m.title ?? t.url.deletingPathExtension().lastPathComponent
                n.artist = m.artist ?? "Unknown Artist"
                n.album = m.album ?? "Unknown Album"
                if m.duration > 0 { n.duration = m.duration }
                updated.append(n)
            }
            await MainActor.run {
                self.tracks = updated
                self.rebuildGroups()
                self.save()
                self.importing = false
                self.statusText = "Refreshed info for \(updated.count) tracks"
            }
        }
    }

    func pruneMissing() {
        let fm = FileManager.default
        let kept = tracks.filter { t in
            if fm.fileExists(atPath: t.path) { return true }
            let parent = (t.path as NSString).deletingLastPathComponent
            return !fm.fileExists(atPath: parent)   // folder gone/unmounted: keep the track
        }
        if kept.count != tracks.count {
            tracks = kept
            rebuildGroups()
            save()
        }
    }

    func rescan() {
        lastScan = Date()
        pruneMissing()
        let urls = watchedFolders.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { importURLs(urls, watch: false) }
    }

    func removeWatched(_ path: String) {
        watchedFolders.removeAll { $0 == path }
        save()
    }

    /// Called at launch: watches ~/Music by default, rescans now, on app activation, and every 2 minutes.
    func startAutoScan() {
        let ud = UserDefaults.standard
        if !ud.bool(forKey: "defaultFolderAdded") {
            ud.set(true, forKey: "defaultFolderAdded")
            if let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first,
               !watchedFolders.contains(music.path) {
                watchedFolders.append(music.path)
                save()
            }
        }
        rescan()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if Date().timeIntervalSince(self.lastScan) > 30 { self.rescan() }
        }
        let t = Timer(timeInterval: 120, repeats: true) { [weak self] _ in self?.rescan() }
        RunLoop.main.add(t, forMode: .common)
        scanTimer = t
    }

    /// Uses Spotlight to find music files in every folder on this Mac.
    func scanWholeMac() {
        guard !scanningMac else { return }
        scanningMac = true
        statusText = "Searching this Mac for music…"
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemContentTypeTree == 'public.audio'")
        q.searchScopes = [NSMetadataQueryLocalComputerScope]
        query = q
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            q.disableUpdates()
            var urls: [URL] = []
            for case let item as NSMetadataItem in q.results {
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                if path.hasPrefix("/System") || path.hasPrefix("/Library") || path.hasPrefix("/Applications") || path.contains("/Library/") { continue }
                if !Library.supportedExtensions.contains((path as NSString).pathExtension.lowercased()) { continue }
                let size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.intValue ?? 0
                if size < 300_000 { continue }
                urls.append(URL(fileURLWithPath: path))
            }
            q.stop()
            self.query = nil
            self.scanningMac = false
            self.statusText = "Found \(urls.count) audio files"
            if !urls.isEmpty { self.importURLs(urls, watch: false) }
        }
        q.start()
    }

    func removeTracks(_ ids: Set<UUID>) {
        tracks.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { ids.contains($0) } }
        bookmarks.removeAll { ids.contains($0.trackID) }
        rebuildGroups()
        save()
    }

    // MARK: Playlists

    @discardableResult
    func addPlaylist(_ name: String) -> UUID {
        let p = Playlist(name: name.isEmpty ? "New Playlist" : name)
        playlists.append(p)
        save()
        return p.id
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        playlists[i].name = name
        save()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func add(_ trackID: UUID, to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if !playlists[i].trackIDs.contains(trackID) { playlists[i].trackIDs.append(trackID) }
        save()
    }

    func removeFromPlaylist(_ playlistID: UUID, at offsets: IndexSet) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.remove(atOffsets: offsets)
        save()
    }

    func movePlaylistTrack(_ playlistID: UUID, from: IndexSet, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.move(fromOffsets: from, toOffset: to)
        save()
    }

    // MARK: Bookmarks

    func addBookmark(track: Track, time: Double, label: String) {
        let l = label.isEmpty ? "Bookmark at \(fmtTime(time))" : label
        bookmarks.append(Bookmark(trackID: track.id, time: time, label: l))
        save()
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    // MARK: History / resume

    func noteStarted(_ track: Track) {
        history.removeAll { $0 == track.id }
        history.insert(track.id, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        lastTrackID = track.id
        saveState()
    }

    func setPosition(_ id: UUID, _ t: Double) {
        positions[id.uuidString] = t
        saveState()
    }

    func clearHistory() {
        history.removeAll()
        saveState()
    }
}
