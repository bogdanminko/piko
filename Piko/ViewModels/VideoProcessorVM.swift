import SwiftUI
import UniformTypeIdentifiers

@Observable
class VideoProcessorVM {
    var videoURL: URL?
    var selectedStyle: SubtitleStyleType = .mrbeast
    var wordMode: WordMode = .static
    var highlightColorHex: String = highlightPalette[0].hex
    var state: ProcessingState = .idle
    var progressPercent: Double = 0
    var progressMessage: String = ""
    var outputURL: URL?
    var subtitleURL: URL?
    var detectedLanguage: String?
    var wordCount: Int = 0
    var keywordsFound: Int = 0

    /// Path of the cached transcription JSON; set after the first (slow)
    /// pass so style changes only need a fast re-render.
    private(set) var transcriptionPath: String?

    /// Finished renders for this video, keyed by output path (one per
    /// style/mode/color combination) — switching back is instant.
    private struct RenderResult {
        let outputPath: String
        let subtitlePath: String
        let keywordsFound: Int
    }
    private var renderCache: [String: RenderResult] = [:]

    private let backend = BackendService()

    // --- Output location ---

    private static let outputDirKey = "outputDirOverride"

    /// Custom output folder chosen by the user; nil = default
    /// ("piko_output" next to the source video). Persisted.
    var outputDirOverride: String? = UserDefaults.standard.string(forKey: "outputDirOverride") {
        didSet {
            UserDefaults.standard.set(outputDirOverride, forKey: Self.outputDirKey)
        }
    }

    /// Effective output folder for the current video, for display.
    var outputDirDescription: String {
        if let dir = outputDirOverride {
            return (dir as NSString).abbreviatingWithTildeInPath
        }
        return "piko_output (next to video)"
    }

    func outputDir(for video: URL) -> URL {
        if let dir = outputDirOverride {
            return URL(fileURLWithPath: dir)
        }
        return video.deletingLastPathComponent()
            .appendingPathComponent("piko_output")
    }

    func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"

        if panel.runModal() == .OK, let url = panel.url {
            outputDirOverride = url.path
        }
    }

    func resetOutputDir() {
        outputDirOverride = nil
    }

    var hasVideo: Bool { videoURL != nil }
    var isProcessing: Bool {
        if case .processing = state { return true }
        return false
    }
    var canReRender: Bool { transcriptionPath != nil && videoURL != nil }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        let videoTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        for type in videoTypes {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                    if let url = item as? URL {
                        Task { @MainActor in self.setVideo(url) }
                    } else if let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) {
                        Task { @MainActor in self.setVideo(url) }
                    }
                }
                return true
            }
        }
        return false
    }

    func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            setVideo(url)
        }
    }

    private func setVideo(_ url: URL) {
        videoURL = url
        state = .idle
        transcriptionPath = nil
        renderCache = [:]
    }

    /// Full pipeline: transcribe (slow, cached by backend) then render.
    func processVideo(modelId: String) async {
        guard let videoURL else { return }

        state = .processing(stage: "starting", percent: 0, message: "Starting...")

        // Stage 1: transcription — mapped to 0...70% of overall progress.
        let params: [String: Any] = [
            "video_path": videoURL.path,
            "model": modelId,
        ]

        for await message in await backend.execute(command: "transcribe", params: params) {
            await MainActor.run {
                switch message.type {
                case "progress":
                    let pct = message.percent ?? 0
                    let msg = message.message ?? ""
                    state = .processing(stage: message.stage ?? "", percent: pct, message: msg)
                    progressPercent = pct
                    progressMessage = msg

                case "result" where message.success == true:
                    transcriptionPath = message.transcriptionPath
                    detectedLanguage = message.language
                    wordCount = message.wordCount ?? 0

                case "error":
                    state = .error(message: message.message ?? "Unknown error")

                default:
                    break
                }
            }
        }

        // transcriptionPath is nil'd on video change and only set by a
        // successful transcribe result above.
        guard transcriptionPath != nil else { return }

        // Stage 2: render — mapped to 70...100%.
        await render(progressBase: 70, progressSpan: 30)
    }

    /// Re-render with the current style using the cached transcription.
    /// Called when the user switches style after a completed run.
    func reRender() async {
        guard canReRender, !isProcessing else { return }
        await render(progressBase: 0, progressSpan: 100)
    }

    private func render(progressBase: Double, progressSpan: Double) async {
        guard let videoURL, let transcriptionPath else { return }

        let style = selectedStyle.rawValue
        // Output path encodes every setting that affects the result,
        // so each combination gets its own file and cache slot.
        var suffix = "_subtitled_\(style)"
        if wordMode != .static {
            suffix += "_\(wordMode.rawValue)"
            if wordMode == .highlight {
                suffix += "_\(highlightColorHex.dropFirst().lowercased())"
            }
        }
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let outputPath = outputDir(for: videoURL)
            .appendingPathComponent(baseName + suffix + ".mp4").path

        // Already rendered with these exact settings — reuse instantly.
        if let cached = renderCache[outputPath],
           FileManager.default.fileExists(atPath: cached.outputPath) {
            outputURL = URL(fileURLWithPath: cached.outputPath)
            subtitleURL = URL(fileURLWithPath: cached.subtitlePath)
            keywordsFound = cached.keywordsFound
            state = .done(outputPath: cached.outputPath,
                          subtitlePath: cached.subtitlePath)
            return
        }

        state = .processing(stage: "rendering",
                            percent: progressBase,
                            message: "Rendering \(selectedStyle.displayName) subtitles...")

        let params: [String: Any] = [
            "video_path": videoURL.path,
            "transcription_path": transcriptionPath,
            "style": style,
            "output_path": outputPath,
            "word_mode": wordMode.rawValue,
            "highlight_color": highlightColorHex,
        ]

        for await message in await backend.execute(command: "render", params: params) {
            await MainActor.run {
                switch message.type {
                case "progress":
                    let raw = message.percent ?? 0
                    let pct = progressBase + raw / 100 * progressSpan
                    let msg = message.message ?? ""
                    state = .processing(stage: message.stage ?? "", percent: pct, message: msg)
                    progressPercent = pct
                    progressMessage = msg

                case "result" where message.success == true:
                    if let outPath = message.outputPath, let subPath = message.subtitlePath {
                        outputURL = URL(fileURLWithPath: outPath)
                        subtitleURL = URL(fileURLWithPath: subPath)
                        if let lang = message.language { detectedLanguage = lang }
                        wordCount = message.wordCount ?? wordCount
                        keywordsFound = message.keywordsFound ?? 0
                        renderCache[outPath] = RenderResult(
                            outputPath: outPath,
                            subtitlePath: subPath,
                            keywordsFound: message.keywordsFound ?? 0
                        )
                        state = .done(outputPath: outPath, subtitlePath: subPath)
                    }

                case "error":
                    state = .error(message: message.message ?? "Unknown error")

                default:
                    break
                }
            }
        }
    }

    func reset() {
        videoURL = nil
        state = .idle
        outputURL = nil
        subtitleURL = nil
        transcriptionPath = nil
        renderCache = [:]
        progressPercent = 0
        progressMessage = ""
    }
}
