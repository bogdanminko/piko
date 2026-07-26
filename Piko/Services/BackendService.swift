import Foundation

actor BackendService {
    private let projectRoot: URL

    init() {
        // Find project root (where pyproject.toml lives)
        // In development, this is the working directory
        let bundle = Bundle.main.bundleURL
        // Try to find pyproject.toml by walking up from bundle
        var dir = bundle
        for _ in 0..<5 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("pyproject.toml").path) {
                self.projectRoot = dir
                return
            }
        }
        // Fallback: current working directory
        self.projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    func execute(command: String, params: [String: Any]? = nil) -> AsyncStream<BackendMessage> {
        AsyncStream { continuation in
            Task {
                do {
                    let process = Process()
                    // Use the uv binary from ~/.local/bin
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    let uvPath = home.appendingPathComponent(".local/bin/uv").path
                    process.executableURL = URL(fileURLWithPath: uvPath)
                    process.arguments = ["run", "--project", projectRoot.path, "python", "-m", "piko.main"]
                    process.currentDirectoryURL = projectRoot

                    let stdinPipe = Pipe()
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardInput = stdinPipe
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    try process.run()

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
                        let errorMsg = BackendMessage(
                            type: "error", stage: nil, percent: nil,
                            message: "Process exited with code \(process.terminationStatus): \(stderr)",
                            success: false, outputPath: nil, subtitlePath: nil,
                            language: nil, wordCount: nil, keywordsFound: nil,
                            models: nil, code: "PROCESS_ERROR", downloaded: nil, model: nil
                        )
                        continuation.yield(errorMsg)
                    }
                } catch {
                    let errorMsg = BackendMessage(
                        type: "error", stage: nil, percent: nil,
                        message: error.localizedDescription,
                        success: false, outputPath: nil, subtitlePath: nil,
                        language: nil, wordCount: nil, keywordsFound: nil,
                        models: nil, code: "SWIFT_ERROR", downloaded: nil, model: nil
                    )
                    continuation.yield(errorMsg)
                }
                continuation.finish()
            }
        }
    }
}
