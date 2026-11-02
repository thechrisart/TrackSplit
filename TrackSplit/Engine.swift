import Foundation

/// One JSON line from tracksplit_engine.py.
struct EngineEvent {
    let event: String
    let values: [String: Any]

    var stage: String? { values["stage"] as? String }
    var percent: Double? { (values["percent"] as? NSNumber)?.doubleValue }
    var message: String? { values["message"] as? String }
    var label: String? { values["label"] as? String }
    var step: Int? { (values["step"] as? NSNumber)?.intValue }
    var steps: Int? { (values["steps"] as? NSNumber)?.intValue }
}

/// The separation runtime TrackSplit owns: a Python venv with audio-separator,
/// PyTorch (Metal) and a static FFmpeg, plus the htdemucs_ft model, under
/// ~/Library/Application Support/TrackSplit. Built once by the bundled engine.
enum Runtime {
    static let dataDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TrackSplit", isDirectory: true)
    static var python: URL { dataDirectory.appendingPathComponent("runtime/bin/python3") }
    static var readyMarker: URL { dataDirectory.appendingPathComponent("ready.json") }

    static var engineScript: URL {
        Bundle.main.resourceURL!.appendingPathComponent("Engine/tracksplit_engine.py")
    }

    static var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: readyMarker.path)
    }

    /// A Python 3.10–3.13 to build the venv with (audio-separator refuses 3.14).
    static func findInterpreter() -> URL? {
        var candidates: [String] = []
        for minor in [12, 13, 11, 10] {
            candidates += [
                "/opt/homebrew/bin/python3.\(minor)",
                "/usr/local/bin/python3.\(minor)",
                "/Library/Frameworks/Python.framework/Versions/3.\(minor)/bin/python3.\(minor)",
                "/opt/homebrew/opt/python@3.\(minor)/bin/python3.\(minor)",
            ]
        }
        return candidates.lazy.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Runs the engine script as a child process and streams its events.
final class EngineProcess {
    private let process = Process()
    private var buffer = Data()
    private var tail: [String] = []
    private let onEvent: (EngineEvent) -> Void

    init(interpreter: URL, arguments: [String], onEvent: @escaping (EngineEvent) -> Void) {
        self.onEvent = onEvent
        process.executableURL = interpreter
        // -I: ignore user site-packages and PYTHON* variables.
        process.arguments = ["-I", Runtime.engineScript.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment
    }

    /// Starts the process and returns its exit status once it ends.
    func run() async -> (status: Int32, lastLines: [String]) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.consume(chunk)
        }
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { [weak self] process in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd() { self?.consume(rest) }
                let result = (process.terminationStatus, self?.tail ?? [])
                // Queued behind the events already posted, so they land first.
                DispatchQueue.main.async { continuation.resume(returning: result) }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (-1, ["Não foi possível iniciar o Python: \(error.localizedDescription)"]))
            }
        }
    }

    /// SIGTERM: the engine stops the separator and removes its temporary files.
    func cancel() {
        if process.isRunning { process.terminate() }
    }

    private let lock = NSLock()

    private func consume(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let text = String(data: line, encoding: .utf8), !text.isEmpty else { continue }
            if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               let name = object["event"] as? String {
                let event = EngineEvent(event: name, values: object)
                DispatchQueue.main.async { self.onEvent(event) }
            } else {
                tail = Array((tail + [text]).suffix(8))
            }
        }
    }
}
