import AppKit
import Foundation

/// One track on the drive, with the stem names the deck mod will ask for.
struct DriveTrack: Identifiable, Hashable {
    let track: RekordboxExport.Track
    let fileURL: URL
    /// The music file's basename up to its last dot, exactly as
    /// `stem_path_for_track` in rx3_core_hook.c builds it: no trimming.
    let base: String
    var hasStems: Bool
    var fileExists: Bool

    var id: UInt32 { track.id }
    var displayName: String {
        let title = track.title.isEmpty ? fileURL.lastPathComponent : track.title
        return track.artist.isEmpty ? title : "\(track.artist) – \(title)"
    }
}

struct DrivePlaylist: Identifiable, Hashable {
    let id: UInt32
    let path: String
    let trackIDs: [UInt32]
}

/// A mounted USB drive carrying a rekordbox export.
struct Drive: Identifiable {
    static let stemsFolder = "RX3_STEMS"
    static let suffixes = [".rx3stem", ".rx3drums", ".rx3bass"]
    /// A container shorter than its own header is an interrupted write.
    static let minimumStemBytes: Int64 = 64
    /// PCM s16 stereo 44.1 kHz, three roles.
    static let bytesPerAudioSecond: Int64 = 44_100 * 4 * Int64(suffixes.count)

    let root: URL
    let name: String
    var tracks: [DriveTrack]
    var playlists: [DrivePlaylist]
    var freeBytes: Int64

    var id: String { root.path }
    var stemsDirectory: URL { root.appendingPathComponent(Self.stemsFolder, isDirectory: true) }

    static func isRekordboxDrive(_ root: URL) -> Bool {
        let manager = FileManager.default
        var directory: ObjCBool = false
        return manager.fileExists(atPath: root.appendingPathComponent("PIONEER").path, isDirectory: &directory) && directory.boolValue
            && manager.fileExists(atPath: root.appendingPathComponent("Contents").path, isDirectory: &directory) && directory.boolValue
    }

    static func exportURL(_ root: URL) -> URL {
        root.appendingPathComponent("PIONEER/rekordbox/export.pdb")
    }

    /// Basename up to the last dot, the way the deck derives it.
    static func stemBase(forPath path: String) -> String {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return name }
        return String(name[..<dot])
    }

    static func load(root: URL) throws -> Drive {
        let export = try RekordboxExport.load(exportURL(root))
        let stems = root.appendingPathComponent(stemsFolder, isDirectory: true)
        let manager = FileManager.default
        var tracks: [DriveTrack] = []
        for track in export.tracks {
            let relative = track.filePath.hasPrefix("/") ? String(track.filePath.dropFirst()) : track.filePath
            let fileURL = root.appendingPathComponent(relative)
            let base = stemBase(forPath: track.filePath)
            tracks.append(DriveTrack(
                track: track, fileURL: fileURL, base: base,
                hasStems: hasAllStems(base: base, in: stems),
                fileExists: manager.fileExists(atPath: fileURL.path)))
        }
        let known = Set(tracks.map(\.id))
        let playlists = export.playlists.map {
            DrivePlaylist(id: $0.id, path: $0.path, trackIDs: $0.trackIDs.filter(known.contains))
        }
        return Drive(root: root, name: volumeName(root), tracks: tracks, playlists: playlists,
                     freeBytes: availableBytes(root))
    }

    static func hasAllStems(base: String, in stems: URL) -> Bool {
        suffixes.allSatisfy { suffix in
            let url = stems.appendingPathComponent(base + suffix)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return size > minimumStemBytes
        }
    }

    static func volumeName(_ root: URL) -> String {
        (try? root.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? root.lastPathComponent
    }

    static func availableBytes(_ root: URL) -> Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}

/// Watches /Volumes and reports drives that carry a rekordbox export.
@MainActor
final class DriveMonitor {
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }
    }

    static func candidateRoots() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { $0.path != "/" && Drive.isRekordboxDrive($0) && FileManager.default.fileExists(atPath: Drive.exportURL($0).path) }
    }
}
