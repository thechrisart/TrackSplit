import AppKit
import Foundation

enum RuntimeState: Equatable {
    case checking
    case ready
    case installing(label: String, fraction: Double)
    case failed(String)
    case noPython
}

enum Screen: Equatable {
    case waiting, overview, running, finished
}

struct TrackOutcome: Identifiable {
    let track: DriveTrack
    let succeeded: Bool
    let reason: String?
    let seconds: Double
    var id: UInt32 { track.id }
}

@MainActor
final class AppModel: ObservableObject {
    // Drive
    @Published var screen: Screen = .waiting
    @Published var drive: Drive?
    @Published var driveError: String?
    @Published var otherDrives: [URL] = []

    // Selection: every track by default, or the union of the chosen playlists.
    @Published var allTracks = true
    @Published var selectedPlaylists: Set<UInt32> = []

    // Runtime
    @Published var runtime: RuntimeState = .checking
    @Published var setupDetail: String = ""

    // Job
    @Published var queue: [DriveTrack] = []
    @Published var position = 0
    @Published var trackFraction = 0.0
    @Published var stageText = ""
    @Published var outcomes: [TrackOutcome] = []
    @Published var cancelled = false
    @Published var jobStarted = Date()
    @Published var jobElapsed: TimeInterval = 0

    private let monitor = DriveMonitor()
    private var engine: EngineProcess?
    private var cancelRequested = false
    private var activity: NSObjectProtocol?
    private var separationPass = 0
    private var lastSeparationPercent = 0.0
    private var trackStarted = Date()
    private var ticker: Timer?

    /// Seconds of work per second of audio. Starts from the rate measured on
    /// this Mac (htdemucs_ft on Metal, ~77 s for a 3-minute track) and is
    /// refined with every finished track.
    @Published var secondsPerAudioSecond: Double = {
        let stored = UserDefaults.standard.double(forKey: "secondsPerAudioSecond")
        return stored > 0 ? stored : 0.43
    }()

    init() {
        monitor.onChange = { [weak self] in self?.refreshDrives() }
        monitor.start()
        refreshDrives()
        prepareRuntime()
    }

    // MARK: Drive

    func refreshDrives() {
        guard screen != .running else { return }
        let roots = DriveMonitor.candidateRoots()
        otherDrives = roots
        if let current = drive, roots.contains(where: { $0.path == current.root.path }) {
            if screen == .overview { load(current.root) }
            return
        }
        if let first = roots.first {
            load(first)
        } else {
            drive = nil
            driveError = nil
            if screen != .finished { screen = .waiting }
        }
    }

    func load(_ root: URL) {
        do {
            let loaded = try Drive.load(root: root)
            if drive?.root.path != root.path {
                allTracks = true
                selectedPlaylists = []
            }
            drive = loaded
            driveError = nil
            screen = .overview
        } catch {
            drive = nil
            driveError = "\(Drive.volumeName(root)): \(error.localizedDescription)"
            screen = .waiting
        }
    }

    var selectedTracks: [DriveTrack] {
        guard let drive else { return [] }
        if allTracks { return drive.tracks }
        let byID = Dictionary(drive.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UInt32>()
        var result: [DriveTrack] = []
        for playlist in drive.playlists where selectedPlaylists.contains(playlist.id) {
            for id in playlist.trackIDs where seen.insert(id).inserted {
                if let track = byID[id] { result.append(track) }
            }
        }
        return result
    }

    var pendingTracks: [DriveTrack] { selectedTracks.filter { !$0.hasStems && $0.fileExists } }
    var doneCount: Int { selectedTracks.filter(\.hasStems).count }
    var missingCount: Int { selectedTracks.filter { !$0.hasStems && !$0.fileExists }.count }

    func estimate(for tracks: [DriveTrack]) -> TimeInterval {
        tracks.reduce(0) { $0 + secondsPerAudioSecond * Double(max($1.track.duration, 30)) }
    }

    func bytesNeeded(for tracks: [DriveTrack]) -> Int64 {
        tracks.reduce(0) { $0 + Drive.bytesPerAudioSecond * Int64(max($1.track.duration, 30)) + 4096 }
    }

    var hasRoomForPending: Bool {
        guard let drive else { return false }
        // Margin for the manifest and the rounding of each file to a cluster.
        return bytesNeeded(for: pendingTracks) + 32 * 1_048_576 <= drive.freeBytes
    }

    func playlistCounts(_ playlist: DrivePlaylist) -> (total: Int, done: Int) {
        guard let drive else { return (0, 0) }
        let done = Set(drive.tracks.filter(\.hasStems).map(\.id))
        return (playlist.trackIDs.count, playlist.trackIDs.filter(done.contains).count)
    }

    func togglePlaylist(_ id: UInt32) {
        if allTracks {
            allTracks = false
            selectedPlaylists = [id]
        } else if selectedPlaylists.contains(id) {
            selectedPlaylists.remove(id)
            if selectedPlaylists.isEmpty { allTracks = true }
        } else {
            selectedPlaylists.insert(id)
        }
    }

    // MARK: Runtime

    func prepareRuntime() {
        if Runtime.isReady {
            runtime = .ready
            return
        }
        guard let interpreter = Runtime.findInterpreter() else {
            runtime = .noPython
            return
        }
        runtime = .installing(label: "Preparando o motor de separação", fraction: 0)
        let process = EngineProcess(interpreter: interpreter,
                                    arguments: ["setup", "--data", Runtime.dataDirectory.path]) { [weak self] event in
            guard let self else { return }
            switch event.event {
            case "setup":
                let steps = Double(event.steps ?? 5)
                let step = Double(event.step ?? 1) - 1
                let within = (event.percent ?? 0) / 100
                self.runtime = .installing(label: event.label ?? "", fraction: min(1, (step + within) / steps))
            case "error":
                self.runtime = .failed(event.message ?? "Erro desconhecido")
            default: break
            }
        }
        Task {
            let (status, lines) = await process.run()
            if status == 0, Runtime.isReady {
                runtime = .ready
            } else if case .failed = runtime {
            } else {
                runtime = .failed(lines.last ?? "A instalação terminou com código \(status).")
            }
        }
    }

    // MARK: Job

    var currentTrack: DriveTrack? { position < queue.count ? queue[position] : nil }

    var overallFraction: Double {
        guard !queue.isEmpty else { return 0 }
        let done = queue.prefix(position).reduce(0.0) { $0 + Double(max($1.track.duration, 30)) }
        let current = currentTrack.map { Double(max($0.track.duration, 30)) * trackFraction } ?? 0
        let total = queue.reduce(0.0) { $0 + Double(max($1.track.duration, 30)) }
        return min(1, (done + current) / total)
    }

    var remainingTime: TimeInterval {
        let rest = queue.dropFirst(position + 1)
        let current = currentTrack.map { estimate(for: [$0]) } ?? 0
        let elapsedOnTrack = Date().timeIntervalSince(trackStarted)
        // Whichever is larger: what the estimate leaves, or what the progress
        // of this track implies, so a slow track does not count down to zero.
        var currentLeft = max(0, current - elapsedOnTrack)
        if trackFraction > 0.15 {
            currentLeft = max(currentLeft * 0.5, elapsedOnTrack / trackFraction - elapsedOnTrack)
        }
        return currentLeft + estimate(for: Array(rest))
    }

    func start() {
        guard runtime == .ready, let drive else { return }
        queue = pendingTracks
        guard !queue.isEmpty else { return }
        outcomes = []
        position = 0
        cancelled = false
        cancelRequested = false
        jobStarted = Date()
        jobElapsed = 0
        screen = .running
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Separando stems")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.jobElapsed = Date().timeIntervalSince(self?.jobStarted ?? Date()) }
        }
        Task { await runQueue(drive: drive) }
    }

    func cancel() {
        cancelRequested = true
        cancelled = true
        stageText = "Cancelando…"
        engine?.cancel()
    }

    private func runQueue(drive: Drive) async {
        var usedNames: [String: DriveTrack] = [:]
        while position < queue.count, !cancelRequested {
            let track = queue[position]
            trackFraction = 0
            separationPass = 0
            lastSeparationPercent = 0
            stageText = "Preparando"
            trackStarted = Date()

            // The deck cannot tell two files with one basename apart.
            if let other = usedNames[track.base.lowercased()], other.fileURL != track.fileURL {
                outcomes.append(TrackOutcome(track: track, succeeded: false,
                    reason: "Mesmo nome de arquivo que \(other.fileURL.lastPathComponent); o deck não distingue os dois.",
                    seconds: 0))
                position += 1
                continue
            }
            usedNames[track.base.lowercased()] = track

            let freeNow = Drive.availableBytes(drive.root)
            if freeNow < bytesNeeded(for: [track]) + 8 * 1_048_576 {
                outcomes.append(TrackOutcome(track: track, succeeded: false,
                    reason: "Sem espaço livre no pendrive.", seconds: 0))
                position += 1
                continue
            }

            var failure: String?
            var cancelledHere = false
            let process = EngineProcess(interpreter: Runtime.python, arguments: [
                "separate", "--data", Runtime.dataDirectory.path,
                "--source", track.fileURL.path,
                "--stems-dir", drive.stemsDirectory.path,
                "--base", track.base,
                "--track-id", String(track.id),
                "--title", track.track.title,
                "--artist", track.track.artist,
            ]) { [weak self] event in
                guard let self else { return }
                switch event.event {
                case "stage": self.handleStage(event)
                case "error": failure = event.message
                case "cancelled": cancelledHere = true
                default: break
                }
            }
            engine = process
            let (status, lines) = await process.run()
            engine = nil
            // Let the last queued events land before reading them.
            await Task.yield()
            let seconds = Date().timeIntervalSince(trackStarted)

            if cancelRequested || cancelledHere {
                break
            }
            if status == 0, failure == nil, Drive.hasAllStems(base: track.base, in: drive.stemsDirectory) {
                outcomes.append(TrackOutcome(track: track, succeeded: true, reason: nil, seconds: seconds))
                learnRate(seconds: seconds, duration: track.track.duration)
            } else {
                let reason = failure ?? lines.last ?? "O motor terminou com código \(status)."
                outcomes.append(TrackOutcome(track: track, succeeded: false, reason: reason, seconds: seconds))
            }
            trackFraction = 1
            position += 1
        }
        finish()
    }

    private func handleStage(_ event: EngineEvent) {
        let percent = (event.percent ?? 0) / 100
        switch event.stage {
        case "copying":
            stageText = "Copiando do pendrive"
            trackFraction = 0.01
        case "separating":
            // htdemucs_ft is a bag of four models, and the progress bar
            // restarts for each one.
            if percent + 0.5 < lastSeparationPercent { separationPass += 1 }
            lastSeparationPercent = percent
            let passes = Double(Self.separationPasses)
            let within = min(1, (Double(separationPass) + percent) / passes)
            stageText = "Separando vocal, bateria e baixo"
            trackFraction = max(trackFraction, 0.02 + 0.86 * within)
        case "encoding":
            let role = ["vocals": "vocal", "drums": "bateria", "bass": "baixo"][event.values["role"] as? String ?? ""] ?? ""
            stageText = "Gerando arquivo de \(role)"
            trackFraction = max(trackFraction, 0.88 + 0.08 * percent)
        case "writing":
            stageText = "Gravando no pendrive"
            trackFraction = max(trackFraction, 0.96 + 0.04 * percent)
        default: break
        }
    }

    static let separationPasses = 4

    private func learnRate(seconds: Double, duration: Int) {
        guard duration > 20 else { return }
        let measured = seconds / Double(duration)
        // Weighted toward the newest tracks, so a first run converges quickly.
        secondsPerAudioSecond = secondsPerAudioSecond * 0.6 + measured * 0.4
        UserDefaults.standard.set(secondsPerAudioSecond, forKey: "secondsPerAudioSecond")
    }

    private func finish() {
        ticker?.invalidate()
        ticker = nil
        jobElapsed = Date().timeIntervalSince(jobStarted)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if let root = drive?.root {
            drive = try? Drive.load(root: root)
        }
        screen = .finished
    }

    func backToOverview() {
        screen = .waiting
        refreshDrives()
    }
}

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return "\(hours) h \(String(format: "%02d", minutes)) min" }
        if minutes > 0 { return "\(minutes) min \(String(format: "%02d", secs)) s" }
        return "\(secs) s"
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
