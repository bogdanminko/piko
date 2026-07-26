import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@Observable
class VideoProcessorVM {
    private static let brollKey = "piko.brollEnabled"

    var videoURL: URL?
    var selectedStyle: SubtitleStyleType = .mrbeast
    var wordMode: WordMode = .static
    var highlightColorHex: String = highlightPalette[0].hex
    /// Cut in clips from the local BRoll library during renders. Persisted.
    var brollEnabled: Bool = UserDefaults.standard.bool(forKey: brollKey) {
        didSet { UserDefaults.standard.set(brollEnabled, forKey: Self.brollKey) }
    }
    var state: ProcessingState = .idle
    var progressPercent: Double = 0
    var progressMessage: String = ""
    var outputURL: URL?
    var subtitleURL: URL?
    var detectedLanguage: String?
    var wordCount: Int = 0
    var keywordsFound: Int = 0

    /// Fired every time a render completes (including instant cache swaps);
    /// the shell uses it to update the session history.
    var onRenderCompleted: (() -> Void)?

    // --- Run metrics ---
    // Timestamps cover the full pipeline run (transcribe + render); style
    // re-renders afterwards deliberately don't touch them.

    private(set) var runStartedAt: Date?
    private(set) var runFinishedAt: Date?
    /// Source media duration in seconds (for the realtime factor).
    private(set) var mediaDuration: Double = 0

    /// Live "processed X of Y media seconds" from the current stage.
    private(set) var processedMediaSeconds: Double?
    private(set) var totalMediaSeconds: Double?

    var processingSeconds: Double? {
        guard let started = runStartedAt, let finished = runFinishedAt else { return nil }
        return finished.timeIntervalSince(started)
    }

    /// Words transcribed per second of processing.
    var wordsPerSecond: Double? {
        guard let secs = processingSeconds, secs > 0, wordCount > 0 else { return nil }
        return Double(wordCount) / secs
    }

    /// The standard ASR speed metric: audio duration / processing time
    /// ("2.4× realtime").
    var realtimeFactor: Double? {
        guard let secs = processingSeconds, secs > 0, mediaDuration > 0 else { return nil }
        return mediaDuration / secs
    }

    /// Path of the cached transcription JSON; set after the first (slow)
    /// pass so style changes only need a fast re-render.
    private(set) var transcriptionPath: String?

    /// Finished renders for this video, keyed by output path (one per
    /// style/mode/color combination) — switching back is instant.
    /// Disk-persistence helpers live in VideoProcessorVM+RenderDiskCache.
    struct RenderResult {
        let outputPath: String
        let subtitlePath: String
        let keywordsFound: Int
    }
    var renderCache: [String: RenderResult] = [:]

    private let backend = BackendService()

    // --- Output location ---
    // Everything renders into the app cache; nothing is written next to the
    // user's video. The user explicitly exports via Save when satisfied.

    /// Same directory the Python backend uses (~/Library/Caches/piko).
    static let cacheDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/piko")

    private var rendersDir: URL {
        Self.cacheDir.appendingPathComponent("renders")
    }

    /// Copy the rendered video out of the cache to a user-chosen location.
    func saveVideo() {
        guard let outputURL, let videoURL else { return }
        exportFile(
            from: outputURL,
            suggestedName: videoURL.deletingPathExtension().lastPathComponent + "_subtitled.mp4"
        )
    }

    /// Copy the generated .ass subtitle file to a user-chosen location.
    func saveSubtitles() {
        guard let subtitleURL, let videoURL else { return }
        exportFile(
            from: subtitleURL,
            suggestedName: videoURL.deletingPathExtension().lastPathComponent + ".ass"
        )
    }

    private func exportFile(from source: URL, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save file"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // --- Cache management ---

    /// Total size of the app cache (transcriptions, renders, emoji, previews).
    static func cacheSizeDescription() -> String {
        let fm = FileManager.default
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: cacheDir,
                                          includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let file as URL in enumerator {
                let size = (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0
                total += Int64(size)
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// Wipe the whole app cache. Unsaved renders and cached transcriptions
    /// are gone after this, so the session falls back to the pre-render state.
    func clearCache() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: Self.cacheDir,
                                                   includingPropertiesForKeys: nil) {
            for item in items {
                try? fm.removeItem(at: item)
            }
        }
        renderCache = [:]
        transcriptionPath = nil
        outputURL = nil
        subtitleURL = nil
        UserDefaults.standard.removeObject(forKey: Self.renderMetaKey)
        if case .done = state {
            state = .idle
        }
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
        for type in videoTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
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
        runStartedAt = Date()
        runFinishedAt = nil
        processedMediaSeconds = nil
        totalMediaSeconds = nil
        mediaDuration = (try? await AVURLAsset(url: videoURL).load(.duration).seconds) ?? 0

        // Stage 1: transcription — mapped to 0...70% of overall progress.
        let params: [String: Any] = [
            "video_path": videoURL.path,
            "model": modelId
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
                    if let processed = message.processedSeconds {
                        processedMediaSeconds = processed
                        totalMediaSeconds = message.totalSeconds ?? totalMediaSeconds
                    }

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

        if case .done = state {
            runFinishedAt = Date()
        }
    }

    /// Re-render with the current style using the cached transcription.
    /// Output-path suffix encodes every setting that affects the result,
    /// so each combination gets its own file and cache slot.
    private func renderSuffix(style: String) -> String {
        var suffix = "_subtitled_\(style)"
        if wordMode != .static {
            suffix += "_\(wordMode.rawValue)"
            if wordMode == .highlight {
                suffix += "_\(highlightColorHex.dropFirst().lowercased())"
            }
        }
        if brollEnabled {
            suffix += "_broll"
        }
        return suffix
    }

    /// Called when the user switches style after a completed run.
    func reRender() async {
        guard canReRender, !isProcessing else { return }
        await render(progressBase: 0, progressSpan: 100)
    }

    /// Bypasses the render cache and asks the backend to redo the current
    /// render from scratch. The cache keys only on settings (style/mode/
    /// broll on-off), not on the b-roll library's contents — so adding or
    /// changing clips after a render already exists at that path wouldn't
    /// otherwise be picked up until the source video's mtime changes.
    func forceRerender() async {
        guard canReRender, !isProcessing else { return }
        await render(progressBase: 0, progressSpan: 100, force: true)
    }

    private func render(progressBase: Double, progressSpan: Double, force: Bool = false) async {
        guard let videoURL, let transcriptionPath else { return }

        let style = selectedStyle.rawValue
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let outputPath = rendersDir
            .appendingPathComponent(baseName + renderSuffix(style: style) + ".mp4").path
        let subtitlePath = (outputPath as NSString).deletingPathExtension + ".ass"

        // Already rendered with these exact settings — reuse instantly.
        // The output path encodes every setting, so a file on disk from a
        // previous session is just as good as this session's cache (the
        // .ass sits next to it; mtime check guards against edited sources).
        if !force, serveFromCache(outputPath: outputPath, subtitlePath: subtitlePath, source: videoURL) {
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
            "broll": brollEnabled
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
                    if let processed = message.processedSeconds {
                        processedMediaSeconds = processed
                        totalMediaSeconds = message.totalSeconds ?? totalMediaSeconds
                    }

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
                        Self.rememberKeywords(message.keywordsFound ?? 0, for: outPath)
                        state = .done(outputPath: outPath, subtitlePath: subPath)
                        onRenderCompleted?()
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
        runStartedAt = nil
        runFinishedAt = nil
        mediaDuration = 0
        processedMediaSeconds = nil
        totalMediaSeconds = nil
    }
}
