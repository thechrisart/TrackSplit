import Foundation

/// Reads `PIONEER/rekordbox/export.pdb`, the DeviceSQL database the player itself
/// reads. Port of rx3-toolkit `app/stems/pdb.py` (commit 7d243f8): rows are read
/// through each page's offset index, and a row that does not parse is skipped.
struct RekordboxExport {
    struct Track: Identifiable, Hashable {
        let id: UInt32
        let artistID: UInt32
        let title: String
        let artist: String
        /// Seconds, as rekordbox analysed it.
        let duration: Int
        /// Path on the drive, e.g. `/Contents/Artist/Album/Song.mp3`.
        let filePath: String
    }

    struct Playlist: Identifiable, Hashable {
        let id: UInt32
        let parentID: UInt32
        let sortOrder: UInt32
        let isFolder: Bool
        let name: String
        var path: String
        var trackIDs: [UInt32]
    }

    var tracks: [Track] = []
    var playlists: [Playlist] = []
    var skippedRows = 0

    enum Failure: LocalizedError {
        case notAnExport, damaged(String)
        var errorDescription: String? {
            switch self {
            case .notAnExport: return "O arquivo export.pdb não é um export do rekordbox."
            case .damaged(let detail): return "export.pdb danificado: \(detail)"
            }
        }
    }

    private static let tableTracks: UInt32 = 0
    private static let tableArtists: UInt32 = 2
    private static let tablePlaylistTree: UInt32 = 7
    private static let tablePlaylistEntries: UInt32 = 8

    static func load(_ url: URL) throws -> RekordboxExport {
        try RekordboxExport(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        let reader = Reader(bytes: [UInt8](data))
        guard reader.bytes.count >= 28,
              let zero = reader.u32(0), zero == 0,
              let pageBytes = reader.u32(4), (512...65536).contains(pageBytes),
              let tableCount = reader.u32(8), tableCount <= 64,
              28 + Int(tableCount) * 16 <= reader.bytes.count
        else { throw Failure.notAnExport }

        var index: [UInt32: (UInt32, UInt32)] = [:]
        for entry in 0..<Int(tableCount) {
            let base = 28 + entry * 16
            guard let type = reader.u32(base), let first = reader.u32(base + 8), let last = reader.u32(base + 12) else { continue }
            if index[type] == nil { index[type] = (first, last) }
        }
        let pages = Pages(reader: reader, pageBytes: Int(pageBytes), index: index)

        var artists: [UInt32: String] = [:]
        pages.rows(Self.tableArtists) { page, position in
            guard let subtype = reader.u16(page + position),
                  let artistID = reader.u32(page + position + 4) else { skippedRows += 1; return }
            let nameOffset = subtype & 4 != 0 ? reader.u16(page + position + 10).map(Int.init)
                                              : reader.u8(page + position + 9).map(Int.init)
            guard let nameOffset, let name = reader.string(page, position + nameOffset, pageBytes: Int(pageBytes)) else {
                skippedRows += 1; return
            }
            artists[artistID] = name.trimmingCharacters(in: .whitespaces)
        }

        var parsedTracks: [Track] = []
        pages.rows(Self.tableTracks) { page, position in
            let fixed = 94, stringCount = 21
            guard position + fixed + stringCount * 2 <= Int(pageBytes),
                  let artistID = reader.u32(page + position + 68),
                  let trackID = reader.u32(page + position + 72),
                  let duration = reader.u16(page + position + 84)
            else { skippedRows += 1; return }
            func string(_ slot: Int) -> String? {
                guard let offset = reader.u16(page + position + fixed + slot * 2) else { return nil }
                return reader.string(page, position + Int(offset), pageBytes: Int(pageBytes))
            }
            // Only surrounding whitespace of the whole path goes; a space before
            // the extension is part of the name the deck asks for.
            guard let filePath = string(20)?.trimmingCharacters(in: .whitespacesAndNewlines), !filePath.isEmpty else {
                skippedRows += 1; return
            }
            parsedTracks.append(Track(
                id: trackID, artistID: artistID,
                title: string(17)?.trimmingCharacters(in: .whitespaces) ?? "",
                artist: artists[artistID] ?? "",
                duration: Int(duration), filePath: filePath))
        }
        tracks = parsedTracks

        var tree: [UInt32: Playlist] = [:]
        pages.rows(Self.tablePlaylistTree) { page, position in
            let p = page + position
            guard let parent = reader.u32(p), let sort = reader.u32(p + 8), let id = reader.u32(p + 12),
                  let folder = reader.u32(p + 16),
                  let name = reader.string(page, position + 20, pageBytes: Int(pageBytes))
            else { skippedRows += 1; return }
            tree[id] = Playlist(id: id, parentID: parent, sortOrder: sort, isFolder: folder != 0,
                                name: name.trimmingCharacters(in: .whitespaces), path: "", trackIDs: [])
        }
        var entries: [UInt32: [(UInt32, UInt32)]] = [:]
        pages.rows(Self.tablePlaylistEntries) { page, position in
            let p = page + position
            guard let entry = reader.u32(p), let track = reader.u32(p + 4), let playlist = reader.u32(p + 8) else {
                skippedRows += 1; return
            }
            entries[playlist, default: []].append((entry, track))
        }
        for (id, var playlist) in tree where !playlist.isFolder {
            var names = [playlist.name]
            var parent = tree[playlist.parentID]
            var depth = 0
            while let folder = parent, depth < 32 {
                names.append(folder.name)
                parent = tree[folder.parentID]
                depth += 1
            }
            playlist.path = names.reversed().filter { !$0.isEmpty }.joined(separator: " / ")
            playlist.trackIDs = (entries[id] ?? []).sorted { $0.0 < $1.0 }.map(\.1)
            playlists.append(playlist)
        }
        playlists.sort { ($0.path.localizedStandardCompare($1.path)) == .orderedAscending }
    }
}

private struct Reader {
    let bytes: [UInt8]

    func u8(_ at: Int) -> UInt8? { at >= 0 && at < bytes.count ? bytes[at] : nil }
    func u16(_ at: Int) -> UInt16? {
        guard at >= 0, at + 2 <= bytes.count else { return nil }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }
    func u32(_ at: Int) -> UInt32? {
        guard at >= 0, at + 4 <= bytes.count else { return nil }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    /// A DeviceSQL string at `page + position`, never reading past the page.
    func string(_ page: Int, _ position: Int, pageBytes: Int) -> String? {
        let start = page + position
        let pageEnd = min(bytes.count, page + pageBytes)
        guard let kind = u8(start) else { return nil }
        if kind == 0x40 || kind == 0x90 {
            guard let length = u16(start + 1), length >= 4 else { return nil }
            let end = min(pageEnd, start + Int(length))
            guard start + 4 <= end else { return "" }
            let raw = Array(bytes[(start + 4)..<end])
            return kind == 0x40 ? String(decoding: raw.map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
                                : String(data: Data(raw), encoding: .utf16LittleEndian)
        }
        let length = Int(kind >> 1)
        guard length >= 1 else { return nil }
        let end = min(pageEnd, start + length)
        guard start + 1 <= end else { return "" }
        return String(data: Data(bytes[(start + 1)..<end]), encoding: .isoLatin1)
    }
}

private struct Pages {
    let reader: Reader
    let pageBytes: Int
    let index: [UInt32: (UInt32, UInt32)]

    /// Calls `body(pageStart, rowOffsetInPage)` for every row of one table.
    func rows(_ table: UInt32, _ body: (Int, Int) -> Void) {
        guard let (first, last) = index[table] else { return }
        var current = first
        var visited = Set<UInt32>()
        while visited.insert(current).inserted {
            let start = Int(current) * pageBytes
            guard start >= 0, start + pageBytes <= reader.bytes.count,
                  let pageType = reader.u32(start + 8), let next = reader.u32(start + 12),
                  let b24 = reader.u8(start + 24), let b25 = reader.u8(start + 25),
                  let b26 = reader.u8(start + 26), let b27 = reader.u8(start + 27)
            else { return }
            let rowCount = (Int(b24) | Int(b25) << 8 | Int(b26) << 16) & 0x1FFF
            if pageType == table, b27 & 0x40 == 0, rowCount > 0 {
                pageRows(start, rowCount, body)
            }
            if current == last { return }
            current = next
        }
    }

    private func pageRows(_ page: Int, _ rowCount: Int, _ body: (Int, Int) -> Void) {
        let groups = (rowCount - 1) / 16 + 1
        var emitted = Set<Int>()
        for group in 0..<groups {
            let base = pageBytes - group * 36
            guard base - 4 >= 0, let present = reader.u16(page + base - 4) else { return }
            let remaining = min(16, rowCount - group * 16)
            for slot in 0..<remaining where (present >> slot) & 1 == 1 {
                let slotPosition = base - 6 - 2 * slot
                guard slotPosition >= 0, let offset = reader.u16(page + slotPosition) else { return }
                let position = 40 + Int(offset)
                if position >= pageBytes || !emitted.insert(position).inserted { continue }
                body(page, position)
            }
        }
    }
}
