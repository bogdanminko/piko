import Foundation

/// One Python process that stays alive, for the commands where loading the
/// model is most of the cost.
///
/// The one-shot protocol — spawn, write one command, close stdin, read to EOF —
/// is right for transcription and rendering: they are rare, heavy, and a fresh
/// process is a free guarantee that nothing leaked. It is wrong for chat.
/// Closing stdin ends `main.py`'s loop, which runs `_shutdown()`, which calls
/// `pool.release()`, which frees 4.4 GB of weights — so every message paid the
/// load again. Measured at 3.7 s per message, identical on the second one,
/// which is what "no reuse at all" looks like.
///
/// Both halves were already built for this. `main.py`'s loop reads *lines* from
/// stdin and its docstring says so; `pool.py` exists precisely so "the session
/// outlives the command that created it". Swift was the only piece closing the
/// pipe.
///
/// **Serialized by design.** An `LLMSession` wraps one decode loop, so two
/// concurrent generations would interleave inside the model, not just in the
/// output. Requests queue on the actor; the caller sees an `AsyncStream` either
/// way.
actor ResidentBackend {
    /// Commands worth keeping a process for: the ones whose cost is the model.
    static let residentCommands: Set<String> = [
        "chat", "summarize_meeting", "warmup_llm", "llm_status", "release_llm"
    ]

    private let projectRoot: URL
    private let venvPython: URL

    private var process: Process?
    private var stdin: FileHandle?
    private var reader: LineReader?

    init(projectRoot: URL, venvPython: URL) {
        self.projectRoot = projectRoot
        self.venvPython = venvPython
    }

    /// Send one command and stream its messages back.
    ///
    /// A message with `type` of `result` or `error` ends the request — that is
    /// the frame. It is the same terminator the one-shot path relied on when it
    /// read to EOF, made explicit now that EOF no longer arrives.
    func send(command: String, params: [String: Any]?) -> AsyncStream<BackendMessage> {
        AsyncStream { continuation in
            Task {
                do {
                    try await self.write(command: command, params: params)
                    while let message = await self.readLine() {
                        continuation.yield(message)
                        if message.type == "result" || message.type == "error" { break }
                    }
                } catch {
                    continuation.yield(BackendMessage(
                        type: "error",
                        message: error.localizedDescription,
                        success: false, code: "RESIDENT_ERROR"
                    ))
                }
                continuation.finish()
            }
        }
    }

    /// Drop the process, and the model with it. The next request starts a new
    /// one — which is what makes "Eject" honest rather than a flag nobody
    /// checks.
    func shutdown() {
        if let process, process.isRunning {
            BackendProcessRegistry.shared.unregister(process)
            process.terminate()
        }
        process = nil
        stdin = nil
        reader = nil
    }

    // MARK: - The process

    private func ensureRunning() throws {
        if let process, process.isRunning { return }
        shutdown()

        let process = Process()
        process.executableURL = venvPython
        process.arguments = ["-m", "piko.main"]
        process.currentDirectoryURL = projectRoot

        let inPipe = Pipe()
        let outPipe = Pipe()
        // Left attached rather than piped: nothing reads it, and an undrained
        // pipe blocks the child once its buffer fills — the same deadlock
        // `run_ffmpeg` was written to avoid.
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.standardError

        try process.run()
        BackendProcessRegistry.shared.register(process)

        self.process = process
        self.stdin = inPipe.fileHandleForWriting
        self.reader = LineReader(handle: outPipe.fileHandleForReading)
    }

    private func write(command: String, params: [String: Any]?) throws {
        try ensureRunning()
        var payload: [String: Any] = ["command": command]
        if let params { payload["params"] = params }
        var data = try JSONSerialization.data(withJSONObject: payload)
        // One command per line, and the line is what `main.py` iterates.
        data.append(0x0A)
        try stdin?.write(contentsOf: data)
    }

    private func readLine() -> BackendMessage? {
        guard let reader else { return nil }
        while let line = reader.next() {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(BackendMessage.self, from: data)
            else { continue }
            return message
        }
        // The child died — a crash, or a quit. Clear it so the next request
        // starts a fresh one instead of writing into a closed pipe forever.
        shutdown()
        return nil
    }
}

/// Newline-delimited reading over a pipe.
///
/// `availableData` hands back whatever has arrived, which for a streamed answer
/// is usually part of a line and sometimes three of them. Buffering here is
/// what keeps a token split across two reads from being dropped as unparseable
/// JSON — the one-shot path got away with re-splitting on every read because it
/// only ever had to survive until EOF.
private final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func next() -> String? {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                if line.isEmpty { continue }
                return String(data: line, encoding: .utf8)
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}
