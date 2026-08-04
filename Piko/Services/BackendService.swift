import Foundation

/// Every live backend process, so the app can take them down on quit
/// (a child Process does not die with its parent on its own).
final class BackendProcessRegistry: @unchecked Sendable {
    static let shared = BackendProcessRegistry()

    private let lock = NSLock()
    private var processes: Set<Process> = []

    func register(_ process: Process) {
        lock.lock()
        processes.insert(process)
        lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.remove(process)
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let running = processes
        processes.removeAll()
        lock.unlock()
        for process in running where process.isRunning {
            process.terminate()
        }
    }
}

enum BackendError: LocalizedError {
    case bootstrapFailed(String)

    var errorDescription: String? {
        switch self {
        case .bootstrapFailed(let detail):
            return "Python environment setup failed: \(detail)"
        }
    }
}

actor BackendService {
    private let projectRoot: URL

    /// The one long-lived process, shared by every `BackendService` in the app.
    ///
    /// Static because "resident" means one, not one per view model: two
    /// processes holding the same weights is 8.8 GB to save two seconds.
    private static var resident: ResidentBackend?

    init() {
        // The Python backend lives in the repo, not in the app bundle (dev
        // setup by design). Walk up looking for pyproject.toml from:
        // 1. the bundle path — works for build/Piko.app inside the repo;
        // 2. this source file's compile-time path — works when Xcode or
        //    `swift run` builds a bare executable into DerivedData/.build,
        //    far away from the repo.
        let candidates = [
            Bundle.main.bundleURL,
            URL(fileURLWithPath: #filePath)
        ]
        for start in candidates {
            var dir = start
            for _ in 0..<6 {
                dir = dir.deletingLastPathComponent()
                if FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("pyproject.toml").path
                ) {
                    self.projectRoot = dir
                    return
                }
            }
        }
        // Fallback: current working directory
        self.projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    private var venvPython: URL {
        projectRoot.appendingPathComponent(".venv/bin/python")
    }

    /// First launch: build the venv strictly from uv.lock (`uv sync --frozen`).
    /// Every later launch uses .venv/bin/python directly, so uv never gets a
    /// chance to re-resolve or update anything. Re-syncs only when uv.lock
    /// changes (the stamp file holds the lock contents the venv was built from).
    private func ensureEnvironment(_ yield: (BackendMessage) -> Void) throws {
        let fm = FileManager.default
        let lockURL = projectRoot.appendingPathComponent("uv.lock")
        let stampURL = projectRoot.appendingPathComponent(".venv/piko-uv.lock.stamp")

        if fm.isExecutableFile(atPath: venvPython.path),
           let lockData = try? Data(contentsOf: lockURL),
           let stampData = try? Data(contentsOf: stampURL),
           lockData == stampData {
            return
        }

        yield(BackendMessage(type: "progress", stage: "bootstrap", percent: 0,
                             message: "Preparing Python environment (first launch)..."))

        let uvURL = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv")
        let process = Process()
        process.executableURL = uvURL
        process.arguments = ["sync", "--frozen", "--project", projectRoot.path]
        process.currentDirectoryURL = projectRoot
        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? "unknown error"
            throw BackendError.bootstrapFailed(stderr)
        }

        if let lockData = try? Data(contentsOf: lockURL) {
            try? lockData.write(to: stampURL)
        }
    }

    /// Free the resident model and the process holding it.
    static func ejectModel() async {
        await resident?.shutdown()
    }

    func execute(command: String, params: [String: Any]? = nil) -> AsyncStream<BackendMessage> {
        // Anything whose cost is the model goes to the process that already has
        // it. Everything else keeps the one-shot contract: transcription and
        // rendering are rare and heavy, and a fresh process is a free guarantee
        // that nothing they allocated outlives them.
        if ResidentBackend.residentCommands.contains(command) {
            return residentExecute(command: command, params: params)
        }
        return oneShot(command: command, params: params)
    }

    private func residentExecute(command: String,
                                 params: [String: Any]?) -> AsyncStream<BackendMessage> {
        AsyncStream { continuation in
            Task {
                do {
                    try self.ensureEnvironment { continuation.yield($0) }
                } catch {
                    continuation.yield(BackendMessage(
                        type: "error", message: error.localizedDescription,
                        success: false, code: "SWIFT_ERROR"))
                    continuation.finish()
                    return
                }
                let backend = await self.residentBackend()
                for await message in await backend.send(command: command, params: params) {
                    continuation.yield(message)
                }
                continuation.finish()
            }
        }
    }

    private func residentBackend() async -> ResidentBackend {
        if let existing = Self.resident { return existing }
        let backend = ResidentBackend(projectRoot: projectRoot, venvPython: venvPython)
        Self.resident = backend
        return backend
    }

    private func oneShot(command: String, params: [String: Any]? = nil) -> AsyncStream<BackendMessage> {
        AsyncStream { continuation in
            Task {
                do {
                    try self.ensureEnvironment { continuation.yield($0) }

                    let process = Process()
                    process.executableURL = self.venvPython
                    process.arguments = ["-m", "piko.main"]
                    process.currentDirectoryURL = self.projectRoot

                    let stdinPipe = Pipe()
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardInput = stdinPipe
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    try process.run()
                    BackendProcessRegistry.shared.register(process)
                    defer { BackendProcessRegistry.shared.unregister(process) }

                    // When the consumer stops listening — the user cancelled a
                    // transcription — take the child down with it, instead of
                    // leaving Whisper chewing through an hour-long file for
                    // nobody. Fires on normal completion too, where the
                    // process has already exited and this is a no-op.
                    continuation.onTermination = { @Sendable _ in
                        if process.isRunning { process.terminate() }
                    }

                    // Build and write command JSON to stdin
                    var cmdDict: [String: Any] = ["command": command]
                    if let params = params {
                        cmdDict["params"] = params
                    }
                    let jsonData = try JSONSerialization.data(withJSONObject: cmdDict)
                    stdinPipe.fileHandleForWriting.write(jsonData)
                    stdinPipe.fileHandleForWriting.closeFile()

                    // Read stdout line by line
                    let handle = stdoutPipe.fileHandleForReading
                    let decoder = JSONDecoder()

                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }

                        guard let output = String(data: data, encoding: .utf8) else { continue }
                        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)

                        for line in lines {
                            guard let lineData = line.data(using: .utf8) else { continue }
                            if let message = try? decoder.decode(BackendMessage.self, from: lineData) {
                                continuation.yield(message)
                            }
                        }
                    }

                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderr = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                        continuation.yield(BackendMessage(
                            type: "error",
                            message: "Process exited with code \(process.terminationStatus): \(stderr)",
                            success: false, code: "PROCESS_ERROR"
                        ))
                    }
                } catch {
                    continuation.yield(BackendMessage(
                        type: "error",
                        message: error.localizedDescription,
                        success: false, code: "SWIFT_ERROR"
                    ))
                }
                continuation.finish()
            }
        }
    }
}
