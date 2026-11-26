import Foundation
import AVFoundation
import AppKit
import ImageIO

struct TrackMeta {
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double = 0
}

enum MetadataReader {
    private static let titleIDs: [AVMetadataIdentifier] = [.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName]
    private static let artistIDs: [AVMetadataIdentifier] = [.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist, .id3MetadataBand, .iTunesMetadataAlbumArtist]
    private static let albumIDs: [AVMetadataIdentifier] = [.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum]
    private static let artIDs: [AVMetadataIdentifier] = [.commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt]

    private static func allItems(_ asset: AVURLAsset) async -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let c = try? await asset.load(.commonMetadata) { items += c }
        if let m = try? await asset.load(.metadata) { items += m }
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for f in formats {
                if let m = try? await asset.loadMetadata(for: f) { items += m }
            }
        }
        return items
    }

    private static func text(_ item: AVMetadataItem) async -> String? {
        if let s = try? await item.load(.stringValue) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    static func read(url: URL) async -> TrackMeta {
        let asset = AVURLAsset(url: url)
        var meta = TrackMeta()

        if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
            meta.duration = d.seconds
        }
        if meta.duration <= 0, let f = try? AVAudioFile(forReading: url) {
            meta.duration = Double(f.length) / f.processingFormat.sampleRate
        }

        for item in await allItems(asset) {
            var matched = false
            if let id = item.identifier {
                if meta.title == nil, titleIDs.contains(id) { meta.title = await text(item); matched = true }
                if !matched, meta.artist == nil, artistIDs.contains(id) { meta.artist = await text(item); matched = true }
                if !matched, meta.album == nil, albumIDs.contains(id) { meta.album = await text(item); matched = true }
            }
            if !matched, let key = item.commonKey?.rawValue {
                if meta.title == nil, key == "title" { meta.title = await text(item) }
                else if meta.artist == nil, key == "artist" { meta.artist = await text(item) }
                else if meta.album == nil, key == "albumName" { meta.album = await text(item) }
            }
        }

        if url.pathExtension.lowercased() == "flac", let f = FlacTags.parse(url: url) {
            if let t = f.title { meta.title = t }
            if let a = f.artist { meta.artist = a }
            if let a = f.album { meta.album = a }
        }
        return meta
    }

    static func artworkData(url: URL) async -> Data? {
        if url.pathExtension.lowercased() == "flac", let p = FlacTags.parse(url: url)?.picture, !p.isEmpty {
            return p
        }
        let asset = AVURLAsset(url: url)
        for item in await allItems(asset) {
            var isArt = false
            if let id = item.identifier, artIDs.contains(id) { isArt = true }
            if item.commonKey?.rawValue == "artwork" { isArt = true }
            guard isArt else { continue }
            if let d = try? await item.load(.dataValue), !d.isEmpty { return d }
            if let obj = try? await item.load(.value) {
                if let d = obj as? Data, !d.isEmpty { return d }
                if let dict = obj as? [String: Any], let d = dict["data"] as? Data, !d.isEmpty { return d }
            }
        }
        // Cover image sitting next to the song (cover.jpg, folder.png ...)
        let dir = url.deletingLastPathComponent()
        for n in ["cover", "folder", "front", "album", "artwork", "Cover", "Folder"] {
            for e in ["jpg", "jpeg", "png"] {
                let u = dir.appendingPathComponent("\(n).\(e)")
                if let d = try? Data(contentsOf: u), !d.isEmpty { return d }
            }
        }
        return nil
    }
}

// MARK: - FLAC (Vorbis comments + embedded picture)

enum FlacTags {
    struct Result {
        var title: String?
        var artist: String?
        var album: String?
        var picture: Data?
    }

    private static func le32(_ d: Data, _ o: Int) -> Int {
        let s = d.startIndex + o
        return Int(d[s]) | (Int(d[s + 1]) << 8) | (Int(d[s + 2]) << 16) | (Int(d[s + 3]) << 24)
    }

    private static func be32(_ d: Data, _ o: Int) -> Int {
        let s = d.startIndex + o
        return (Int(d[s]) << 24) | (Int(d[s + 1]) << 16) | (Int(d[s + 2]) << 8) | Int(d[s + 3])
    }

    static func parse(url: URL) -> Result? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let magic = try? fh.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }

        var r = Result()
        var last = false
        var loops = 0
        while !last, loops < 64 {
            loops += 1
            guard let h = try? fh.read(upToCount: 4), h.count == 4 else { break }
            let b0 = h[h.startIndex]
            last = (b0 & 0x80) != 0
            let type = b0 & 0x7F
            let len = (Int(h[h.startIndex + 1]) << 16) | (Int(h[h.startIndex + 2]) << 8) | Int(h[h.startIndex + 3])
            if type == 4 || type == 6 {
                guard len < 40_000_000, let body = try? fh.read(upToCount: len), body.count == len else { break }
                if type == 4 { parseComments(body, &r) }
                else if r.picture == nil { r.picture = parsePicture(body) }
            } else {
                guard let pos = try? fh.offset() else { break }
                do { try fh.seek(toOffset: pos + UInt64(len)) } catch { break }
            }
        }
        return r
    }

    private static func parseComments(_ d: Data, _ r: inout Result) {
        guard d.count >= 8 else { return }
        var o = 4 + le32(d, 0)
        guard o >= 0, o + 4 <= d.count else { return }
        let n = le32(d, o)
        o += 4
        var i = 0
        while i < n, o + 4 <= d.count {
            i += 1
            let l = le32(d, o)
            o += 4
            guard l >= 0, o + l <= d.count else { return }
            let s = String(decoding: d[(d.startIndex + o)..<(d.startIndex + o + l)], as: UTF8.self)
            o += l
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = s[s.startIndex..<eq].uppercased()
            let value = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            switch key {
            case "TITLE": r.title = value
            case "ARTIST": r.artist = value
            case "ALBUMARTIST": if r.artist == nil { r.artist = value }
            case "ALBUM": r.album = value
            default: break
            }
        }
    }

    private static func parsePicture(_ d: Data) -> Data? {
        guard d.count > 32 else { return nil }
        var o = 4
        let mimeLen = be32(d, o); o += 4 + mimeLen
        guard o + 4 <= d.count else { return nil }
        let descLen = be32(d, o); o += 4 + descLen
        o += 16
        guard o + 4 <= d.count else { return nil }
        let dataLen = be32(d, o); o += 4
        guard dataLen > 0, o + dataLen <= d.count else { return nil }
        return d.subdata(in: (d.startIndex + o)..<(d.startIndex + o + dataLen))
    }
}

// MARK: - Artwork cache

final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var missing = Set<String>()

    private init() { cache.countLimit = 600 }

    func image(for track: Track) async -> NSImage? {
        let key = track.id.uuidString
        if let img = cache.object(forKey: key as NSString) { return img }
        lock.lock()
        let known = missing.contains(key)
        lock.unlock()
        if known { return nil }

        if let data = await MetadataReader.artworkData(url: track.url),
           let img = ArtworkCache.thumbnail(from: data, maxPixel: 500) {
            cache.setObject(img, forKey: key as NSString)
            return img
        }
        lock.lock()
        missing.insert(key)
        lock.unlock()
        return nil
    }

    func forget() {
        cache.removeAllObjects()
        lock.lock()
        missing.removeAll()
        lock.unlock()
    }

    static func thumbnail(from data: Data, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
