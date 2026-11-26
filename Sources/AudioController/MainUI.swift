import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum NavItem: Hashable {
    case recents, artists, albums, songs
    case allPlaylists
    case playlist(UUID)
    case external, shortcuts, settings
}

func pickMusic() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.message = "Choose music files or folders (folders are watched for new music)"
    if panel.runModal() == .OK { AppController.shared.library.importURLs(panel.urls) }
}

// MARK: - Root

struct MainView: View {
    @ObservedObject var library = AppController.shared.library
    @State private var nav: NavItem = .recents
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(nav: $nav, search: $search)
                .frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                TopBarView()
                Divider()
                content
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Color(white: 0.11))
        .preferredColorScheme(.dark)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        DispatchQueue.main.async { AppController.shared.library.importURLs([url]) }
                    }
                }
            }
            return true
        }
    }

    @ViewBuilder
    var content: some View {
        if !search.isEmpty {
            SongsView(search: search)
        } else {
            switch nav {
            case .recents: RecentsView()
            case .artists: ArtistsView()
            case .albums: AlbumsView()
            case .songs: SongsView(search: "")
            case .allPlaylists: AllPlaylistsView(nav: $nav)
            case .playlist(let id): PlaylistDetailView(id: id, nav: $nav)
            case .external: ExternalView()
            case .shortcuts: ShortcutsView()
            case .settings: SettingsView()
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var nav: NavItem
    @Binding var search: String
    @ObservedObject var library = AppController.shared.library

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12)
            .padding(.top, 40)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    header("Library")
                    row(.recents, "clock", "Recents")
                    row(.artists, "music.mic", "Artists")
                    row(.albums, "square.stack", "Albums")
                    row(.songs, "music.note", "Songs")
                    header("Playlists")
                    row(.allPlaylists, "square.grid.3x3", "All Playlists")
                    ForEach(library.playlists) { p in
                        row(.playlist(p.id), "music.note.list", p.name)
                    }
                    header("Control")
                    row(.external, "dot.radiowaves.left.and.right", "External Audio")
                    row(.shortcuts, "keyboard", "Shortcuts")
                    row(.settings, "gearshape", "Settings")
                }
                .padding(.horizontal, 8)
            }

            Divider()
            HStack {
                Button { pickMusic() } label: { Label("Add Music…", systemImage: "plus") }
                    .buttonStyle(.plain)
                Spacer()
                if library.importing { ProgressView().controlSize(.small) }
            }
            .padding(12)
        }
        .background(Color(white: 0.08))
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.subheadline).foregroundColor(.secondary)
            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
    }

    private func row(_ item: NavItem, _ icon: String, _ title: String) -> some View {
        let selected = (nav == item) && search.isEmpty
        return Button {
            search = ""
            nav = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundColor(selected ? .white : accentRed).frame(width: 20)
                Text(title).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? Color(red: 0.62, green: 0.14, blue: 0.17) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Top bar (transport, now playing, volume, feature buttons)

struct TopBarView: View {
    @ObservedObject var player = AppController.shared.player
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showTools = false
    @State private var showEQ = false
    @State private var showBookmarks = false

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 18) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").foregroundColor(player.shuffle ? accentRed : .secondary)
                }
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22))
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode.symbol)
                        .foregroundColor(player.repeatMode == .off ? .secondary : accentRed)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 17))

            NowPlayingBox()

            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.caption).foregroundColor(.secondary)
                Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...1)
                    .frame(width: 110)
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundColor(.secondary)
            }

            HStack(spacing: 14) {
                Button { showLyrics.toggle() } label: { Image(systemName: "quote.bubble") }
                    .help("Lyrics")
                    .popover(isPresented: $showLyrics, arrowEdge: .bottom) { LyricsPopover() }
                Button { showQueue.toggle() } label: { Image(systemName: "list.bullet") }
                    .help("Up Next and History")
                    .popover(isPresented: $showQueue, arrowEdge: .bottom) { QueuePopover() }
                Button { showTools.toggle() } label: { Image(systemName: "speedometer") }
                    .help("Speed, A-B repeat, sleep timer")
                    .popover(isPresented: $showTools, arrowEdge: .bottom) { ToolsPopover() }
                Button { showBookmarks.toggle() } label: { Image(systemName: "bookmark") }
                    .help("Bookmarks")
                    .popover(isPresented: $showBookmarks, arrowEdge: .bottom) { BookmarksPopover() }
                Button { showEQ.toggle() } label: { Image(systemName: "slider.vertical.3") }
                    .help("Equalizer and normalization")
                    .popover(isPresented: $showEQ, arrowEdge: .bottom) {
                        EqualizerView().frame(width: 620, height: 380)
                    }
            }
            .buttonStyle(.plain)
            .font(.system(size: 17))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 70)
        .background(Color(white: 0.13))
    }
}

struct NowPlayingBox: View {
    @ObservedObject var player = AppController.shared.player
    @State private var scrub: Double?

    var body: some View {
        let pos = scrub ?? player.position
        let frac = player.duration > 0 ? min(1, max(0, pos / player.duration)) : 0
        HStack(spacing: 0) {
            ArtworkView(track: player.current, corner: 0)
                .frame(width: 56, height: 56)
            ZStack(alignment: .bottom) {
                Color.white.opacity(0.07)
                VStack(spacing: 2) {
                    Text(player.current?.title ?? "Not playing").font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(player.current.map { "\($0.artist) — \($0.album)" } ?? "")
                        .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    HStack {
                        Text(fmtTime(pos)).font(.system(size: 9).monospacedDigit())
                        Spacer()
                        Text("-" + fmtTime(max(0, player.duration - pos))).font(.system(size: 9).monospacedDigit())
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                }
                .padding(.bottom, 6)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.12))
                        Rectangle().fill(Color.white.opacity(0.55)).frame(width: g.size.width * CGFloat(frac))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let f = min(1, max(0, v.location.x / max(1, g.size.width)))
                            scrub = f * player.duration
                        }
                        .onEnded { _ in
                            if let s = scrub { player.seek(to: s) }
                            scrub = nil
                        })
                }
            }
        }
        .frame(height: 56)
        .frame(maxWidth: 560)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
    }
}

// MARK: - Artwork

struct ArtworkView: View {
    let track: Track?
    var corner: CGFloat = 6
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(white: 0.3)
            if let img = image {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .resizable().scaledToFit()
                    .padding(14)
                    .foregroundColor(Color.white.opacity(0.35))
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task(id: track?.id) {
            image = nil
            if let t = track { image = await ArtworkCache.shared.image(for: t) }
        }
    }
}

// MARK: - Popovers for the feature buttons

struct LyricsPopover: View {
    @ObservedObject var player = AppController.shared.player

    var lyricIndex: Int? { player.lyrics.lastIndex { $0.time <= player.position + 0.2 } }

    var body: some View {
        VStack {
            if player.lyrics.isEmpty {
                Text("No synced lyrics for this song.\nPut a .lrc file with the same name next to the song file.")
                    .multilineTextAlignment(.center).foregroundColor(.secondary).padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { i, line in
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(i == lyricIndex ? .title3.bold() : .body)
                                    .foregroundColor(i == lyricIndex ? .white : .secondary)
                                    .id(line.id)
                                    .onTapGesture { player.seek(to: line.time) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .onChange(of: lyricIndex) { idx in
                        if let i = idx, i < player.lyrics.count {
                            withAnimation { proxy.scrollTo(player.lyrics[i].id, anchor: .center) }
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: 440)
    }
}

struct QueuePopover: View {
    @ObservedObject var library = AppController.shared.library
    @ObservedObject var player = AppController.shared.player

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Up Next").font(.headline)
                Spacer()
                Button("Clear") { player.clearQueue() }.disabled(player.queue.isEmpty)
            }
            if player.queue.isEmpty {
                Text("Empty. Right-click any song > Add to Queue.").font(.caption).foregroundColor(.secondary)
            }
            List {
                ForEach(player.queue) { t in TrackRow(track: t) }
                    .onMove { player.queue.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { player.queue.remove(atOffsets: $0) }
            }
            .frame(height: 150)
            HStack {
                Text("History").font(.headline)
                Spacer()
                Button("Clear") { library.clearHistory() }.disabled(library.history.isEmpty)
            }
            List(library.historyTracks) { t in
                HStack {
                    TrackRow(track: t)
                    if let pos = library.positions[t.id.uuidString], pos > 5 {
                        Button("Resume \(fmtTime(pos))") {
                            AppController.shared.mode = .internalPlayer
                            player.play(t, in: library.tracks, startAt: pos)
                        }
                    } else {
                        Button("Play") { AppController.shared.playInternal(t, in: library.tracks) }
                    }
                }
            }
        }
        .padding()
        .frame(width: 440, height: 480)
    }
}

struct ToolsPopover: View {
    @ObservedObject var player = AppController.shared.player
    @State private var customSpeed = ""
    @State private var sleepTime = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Playback speed (\(speedLabel(player.rate)))") {
                VStack(alignment: .leading) {
                    HStack {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { s in
                            Button(speedLabel(s)) { player.setRate(s) }
                        }
                    }
                    HStack {
                        TextField("Custom e.g. 1.35", text: $customSpeed).frame(width: 140)
                        Button("Set") {
                            if let v = Double(customSpeed.replacingOccurrences(of: ",", with: ".")) { player.setRate(v) }
                        }
                        Button("1x ⇄ 2x") { player.toggleSpeed() }
                    }
                }
            }
            GroupBox("A-B repeat") {
                HStack {
                    Button("Set A") { player.setA() }
                    Button("Set B") { player.setB() }
                    Button("Clear") { player.clearAB() }
                    Text("A: \(player.abA.map(fmtTime) ?? "—")   B: \(player.abB.map(fmtTime) ?? "—")")
                        .font(.caption.monospacedDigit())
                }
            }
            GroupBox("Sleep timer") {
                VStack(alignment: .leading) {
                    HStack {
                        ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                            Button("\(m) min") { player.setSleep(minutes: Double(m)) }
                        }
                    }
                    HStack {
                        DatePicker("At", selection: $sleepTime, displayedComponents: .hourAndMinute).frame(width: 150)
                        Button("Stop at time") { player.setSleep(at: sleepTime) }
                        Button("Cancel") { player.cancelSleep() }
                    }
                    if let s = player.sleepAt {
                        Text("Playback stops at \(s.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundColor(.orange)
                    }
                }
            }
        }
        .padding()
        .frame(width: 430)
    }
}

struct BookmarksPopover: View {
    @ObservedObject var player = AppController.shared.player
    @ObservedObject var library = AppController.shared.library
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Label (optional)", text: $label)
                Button("Add at \(fmtTime(player.position))") {
                    if let t = player.current {
                        library.addBookmark(track: t, time: player.position, label: label)
                        label = ""
                    }
                }
                .disabled(player.current == nil)
            }
            let marks = library.bookmarks.filter { $0.trackID == player.current?.id }
            if marks.isEmpty {
                Text("No bookmarks for this song.").font(.caption).foregroundColor(.secondary)
            }
            ForEach(marks) { b in
                HStack {
                    Button("\(fmtTime(b.time))  \(b.label)") { player.seek(to: b.time) }
                    Spacer()
                    Button { library.removeBookmark(b.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding()
        .frame(width: 380, height: 260)
    }
}

// MARK: - Track list pieces

struct TrackRow: View {
    let track: Track
    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(track: track, corner: 4).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text("\(track.artist) — \(track.album)").font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Text(fmtTime(track.duration)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
        }
    }
}

struct TrackListView: View {
    let tracks: [Track]
    @ObservedObject var library = AppController.shared.library
    @ObservedObject var player = AppController.shared.player

    var body: some View {
        List(tracks) { t in
            TrackRow(track: t)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { AppController.shared.playInternal(t, in: tracks) }
                .contextMenu {
                    Button("Play") { AppController.shared.playInternal(t, in: tracks) }
                    Button("Play Next") { player.enqueueNext(t) }
                    Button("Add to Queue") { player.enqueue(t) }
                    Menu("Add to Playlist") {
                        ForEach(library.playlists) { pl in
                            Button(pl.name) { library.add(t.id, to: pl.id) }
                        }
                    }
                    Divider()
                    Button("Remove from Library") { library.removeTracks([t.id]) }
                }
        }
    }
}

struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 42)).foregroundColor(.secondary)
            Text("Your library is empty").font(.title3)
            Text("Drag music files or folders anywhere in this window, or add them below.\nFolders are watched, so new music shows up in Recents by itself.")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            HStack {
                Button("Add Music…") { pickMusic() }
                Button("Find Music on This Mac") { AppController.shared.library.scanWholeMac() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

// MARK: - Recents

struct TrackCard: View {
    let track: Track
    let list: [Track]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkView(track: track, corner: 6).frame(width: 150, height: 150)
            Text(track.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(track.artist).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
        }
        .frame(width: 150)
        .contentShape(Rectangle())
        .onTapGesture { AppController.shared.playInternal(track, in: list) }
    }
}

struct RecentsView: View {
    @ObservedObject var library = AppController.shared.library

    var body: some View {
        let played = Array(library.historyTracks.prefix(30))
        let added = Array(library.tracks.sorted { $0.added > $1.added }.prefix(60))
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if library.tracks.isEmpty {
                    EmptyLibraryView()
                } else {
                    if !played.isEmpty { shelf("Recently Played", played) }
                    shelf("Recently Added", added)
                    if !library.statusText.isEmpty {
                        Text(library.statusText).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .padding(24)
        }
    }

    private func shelf(_ title: String, _ items: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(items) { t in TrackCard(track: t, list: items) }
                }
                .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Albums

struct AlbumsView: View {
    @ObservedObject var library = AppController.shared.library
    @State private var selected: String?

    var body: some View {
        if let id = selected, let album = library.albums.first(where: { $0.id == id }) {
            AlbumDetail(album: album) { selected = nil }
        } else if library.albums.isEmpty {
            ScrollView { EmptyLibraryView() }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 22, alignment: .top)], spacing: 24) {
                    ForEach(library.albums) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            ArtworkView(track: a.tracks.first, corner: 6)
                                .aspectRatio(1, contentMode: .fit)
                            Text(a.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Text(a.artist).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selected = a.id }
                    }
                }
                .padding(24)
            }
        }
    }
}

struct AlbumDetail: View {
    let album: AlbumGroup
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Button { back() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                ArtworkView(track: album.tracks.first, corner: 6).frame(width: 110, height: 110)
                VStack(alignment: .leading, spacing: 6) {
                    Text(album.title).font(.title2.bold()).lineLimit(2)
                    Text(album.artist).foregroundColor(accentRed)
                    HStack {
                        Button { if let f = album.tracks.first { AppController.shared.playInternal(f, in: album.tracks) } } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        Button {
                            let player = AppController.shared.player
                            if !player.shuffle { player.toggleShuffle() }
                            if let f = album.tracks.randomElement() { AppController.shared.playInternal(f, in: album.tracks) }
                        } label: { Label("Shuffle", systemImage: "shuffle") }
                    }
                }
                Spacer()
            }
            .padding(20)
            TrackListView(tracks: album.tracks)
        }
    }
}

// MARK: - Artists

struct ArtistsView: View {
    @ObservedObject var library = AppController.shared.library
    @State private var selected: String?

    var body: some View {
        if library.artists.isEmpty {
            ScrollView { EmptyLibraryView() }
        } else {
            HStack(spacing: 0) {
                List(library.artists, selection: $selected) { a in
                    HStack {
                        Image(systemName: "music.mic").foregroundColor(accentRed)
                        Text(a.name).lineLimit(1)
                        Spacer()
                        Text("\(a.tracks.count)").foregroundColor(.secondary)
                    }
                    .tag(a.id)
                }
                .frame(width: 260)
                Divider()
                if let id = selected, let artist = library.artists.first(where: { $0.id == id }) {
                    VStack(alignment: .leading) {
                        Text(artist.name).font(.title2.bold()).padding([.top, .horizontal], 16)
                        TrackListView(tracks: artist.tracks)
                    }
                } else {
                    VStack { Spacer(); Text("Select an artist").foregroundColor(.secondary); Spacer() }
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Songs

struct SongsView: View {
    let search: String
    @ObservedObject var library = AppController.shared.library

    var body: some View {
        let list: [Track] = search.isEmpty
            ? library.tracks
            : library.tracks.filter { ($0.title + " " + $0.artist + " " + $0.album).localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(search.isEmpty ? "Songs" : "Results for “\(search)”").font(.title2.bold())
                Spacer()
                Text("\(list.count)").foregroundColor(.secondary)
            }
            .padding(16)
            if library.tracks.isEmpty {
                ScrollView { EmptyLibraryView() }
            } else {
                TrackListView(tracks: list)
            }
        }
    }
}

// MARK: - Playlists

struct AllPlaylistsView: View {
    @Binding var nav: NavItem
    @ObservedObject var library = AppController.shared.library
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("All Playlists").font(.title2.bold())
                    Spacer()
                    TextField("New playlist name", text: $name).frame(width: 200)
                    Button("New Playlist") {
                        let id = library.addPlaylist(name)
                        name = ""
                        nav = .playlist(id)
                    }
                }
                if library.playlists.isEmpty {
                    Text("No playlists yet.").foregroundColor(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 22, alignment: .top)], spacing: 24) {
                    ForEach(library.playlists) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            ArtworkView(track: library.tracks(in: p).first, corner: 6)
                                .aspectRatio(1, contentMode: .fit)
                            Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text("\(p.trackIDs.count) songs").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { nav = .playlist(p.id) }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct PlaylistDetailView: View {
    let id: UUID
    @Binding var nav: NavItem
    @ObservedObject var library = AppController.shared.library
    @ObservedObject var player = AppController.shared.player
    @State private var name = ""

    var body: some View {
        if let pl = library.playlists.first(where: { $0.id == id }) {
            let items = library.tracks(in: pl)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    TextField("Name", text: Binding(get: { name.isEmpty ? pl.name : name }, set: { name = $0 }))
                        .font(.title2.bold()).textFieldStyle(.plain).frame(maxWidth: 320)
                        .onSubmit { library.renamePlaylist(pl.id, to: name); name = "" }
                    Spacer()
                    Button { if let f = items.first { AppController.shared.playInternal(f, in: items) } } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .disabled(items.isEmpty)
                    Button("Add All to Queue") { items.forEach { player.enqueue($0) } }.disabled(items.isEmpty)
                    Button(role: .destructive) { library.deletePlaylist(pl.id); nav = .allPlaylists } label: {
                        Image(systemName: "trash")
                    }
                }
                .padding(16)
                if items.isEmpty {
                    Text("Right-click songs in Songs, Albums or Artists > Add to Playlist.")
                        .foregroundColor(.secondary).padding(.horizontal, 16)
                }
                List {
                    ForEach(items) { t in
                        TrackRow(track: t)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { AppController.shared.playInternal(t, in: items) }
                    }
                    .onMove { library.movePlaylistTrack(pl.id, from: $0, to: $1) }
                    .onDelete { library.removeFromPlaylist(pl.id, at: $0) }
                }
            }
        } else {
            VStack { Spacer(); Text("Playlist not found").foregroundColor(.secondary); Spacer() }
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var library = AppController.shared.library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Music folders (checked at launch, when the app is opened, and every 2 minutes)") {
                    VStack(alignment: .leading, spacing: 6) {
                        if library.watchedFolders.isEmpty {
                            Text("No folders yet.").foregroundColor(.secondary)
                        }
                        ForEach(library.watchedFolders, id: \.self) { f in
                            HStack {
                                Image(systemName: "folder")
                                Text(f).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { library.removeWatched(f) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                            }
                        }
                        HStack {
                            Button("Add Folder…") { pickMusic() }
                            Button("Rescan Now") { library.rescan() }
                            Button(library.scanningMac ? "Searching…" : "Find Music on This Mac") { library.scanWholeMac() }
                                .disabled(library.scanningMac)
                            Button("Refresh Artist / Album / Artwork") { library.refreshMetadata() }
                            if library.importing { ProgressView().controlSize(.small) }
                        }
                        if !library.statusText.isEmpty {
                            Text(library.statusText).font(.caption).foregroundColor(.secondary)
                        }
                        Text("New songs found automatically appear in Recents > Recently Added.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                GroupBox("Mini-player (menu bar)") {
                    VStack(alignment: .leading) {
                        Text("Opens only when you click the menu bar icon. Close it with the X button, Esc, a click anywhere else, the icon again, or let it hide after \(Int(settings.data.miniPlayerTimeout)) seconds. It never reappears by itself.")
                            .font(.caption).foregroundColor(.secondary)
                        HStack {
                            Text("Auto-hide after")
                            Slider(value: $settings.data.miniPlayerTimeout, in: 5...60, step: 1).frame(width: 220)
                            Text("\(Int(settings.data.miniPlayerTimeout)) s")
                        }
                        Text("Right-click (or Control-click) the menu bar icon for Open / Quit. You can also quit from the Dock icon or Cmd-Q.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                GroupBox("Desktop visualizer") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show visualizer around the screen edges", isOn: $settings.data.visualizerEnabled)
                        Picker("Sides", selection: Binding(
                            get: { settings.data.visualizerEdges[1] ? 4 : 3 },
                            set: { settings.data.visualizerEdges = ($0 == 4) ? [true, true, true, true] : [true, false, true, true] })) {
                            Text("All 4 sides").tag(4)
                            Text("3 sides (no bottom)").tag(3)
                        }
                        .pickerStyle(.segmented).frame(width: 340)
                        Picker("Style", selection: $settings.data.visualizerStyle) {
                            Text("Bars").tag("bars")
                            Text("Glow").tag("glow")
                        }
                        .pickerStyle(.segmented).frame(width: 240)
                        Toggle("Multi-color spectrum", isOn: $settings.data.visualizerRainbow)
                        ColorPicker("Single color (when spectrum is off)", selection: Binding<Color>(
                            get: { Color(nsColor: NSColor(hex: settings.data.visualizerColor)) },
                            set: { settings.data.visualizerColor = NSColor($0).hexString }))
                            .frame(width: 340)
                        HStack {
                            Text("Bar thickness")
                            Slider(value: $settings.data.visualizerBarWidth, in: 1...6, step: 0.5).frame(width: 200)
                            Text(String(format: "%.1f px", settings.data.visualizerBarWidth))
                        }
                        HStack {
                            Text("Bar height")
                            Slider(value: $settings.data.visualizerThickness, in: 10...140, step: 2).frame(width: 200)
                            Text("\(Int(settings.data.visualizerThickness)) px")
                        }
                        Text("The visualizer reacts to music from the internal player. It does not react to other apps' audio (that needs screen-recording permission and is not included).")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                GroupBox("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Formats: MP3, WAV, FLAC, AAC, M4A, AIFF, CAF. OGG is not supported by macOS audio APIs.")
                        Text("Artwork, artist and album are read from the file tags (ID3, MP4, FLAC), or a cover.jpg/folder.jpg next to the song.")
                        Text("Lyrics: place a .lrc file next to the song with the same file name.")
                        Text("Everything is stored locally; nothing needs the internet.")
                    }
                    .font(.caption)
                }
            }
            .padding()
        }
    }
}
