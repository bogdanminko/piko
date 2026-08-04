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
    /// Unstyled subtitle files. Written by every render, including the
    /// subtitle-only one that runs the moment a transcript exists, so the
    /// cheapest export never waits behind an encode.
    var srtURL: URL?
    var vttURL: URL?
    var detectedLanguage: String?
    var wordCount: Int = 0
    var keywordsFound: Int = 0

    /// The transcript as shown and corrected. Nil until the first pass.
    var transcript: CaptionTranscript?
    /// Corrections, stored per source video and composed into the copy the
    /// renderer reads. Never written back into the cached transcription.
    /// Maintained by VideoProcessorVM+Transcript.
    var edits: CaptionEdits = .empty
    /// Corrections that no longer match any line after a re-transcription.
    /// Kept in the file and reported rather than dropped.
    var unplacedEdits: Int = 0

    /// The run in flight, so it can be cancelled. Cancelling the task ends
    /// the backend stream, which terminates the Python process with it.
    private var runTask: Task<Void, Never>?

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

    // Derived figures live in VideoProcessorVM+Metrics.

    /// Path of the cached transcription JSON; set after the first (slow)
    /// pass so style changes only need a fast re-render.
    var transcriptionPath: String?

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

    var rendersDir: URL {
        Self.cacheDir.appendingPathComponent("renders")
    }

    // Saving out to the user's own disk lives in VideoProcessorVM+Export,
    // reading and correcting the words in VideoProcessorVM+Transcript, and
    // everything about the cache in VideoProcessorVM+RenderDiskCache.

    var hasVideo: Bool { videoURL != nil }
    var isProcessing: Bool {
        if case .processing = state { return true }
        return false
    }
    var canReRender: Bool { transcriptionPath != nil && videoURL != nil }
    var hasTranscript: Bool { transcript != nil }

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
        transcript = nil
        srtURL = nil
        vttURL = nil
        renderCache = [:]
        edits = CaptionEdits.load(forVideoAt: url.path)
        unplacedEdits = 0
    }

    // MARK: - Running

    /// Start the transcription pass. Owned by the view model rather than the
    /// caller's task so that Cancel has something to cancel.
    func start(modelId: String) {
        runTask?.cancel()
        runTask = Task { [weak self] in await self?.transcribeThenOfferExports(modelId: modelId) }
    }

    /// Stop whatever is running. Ending the stream terminates the Python
    /// process (BackendService hangs that off `continuation.onTermination`),
    /// so an hour-long file no longer has to be escaped by quitting the app.
    func cancel() {
        runTask?.cancel()
        runTask = nil
        progressPercent = 0
        progressMessage = ""
        processedMediaSeconds = nil
        totalMediaSeconds = nil
        state = hasTranscript ? .transcribed : .idle
    }

    /// Burn the captions into the video — the one step that costs a full
    /// re-encode, and therefore the one step the user asks for explicitly.
    func burn() {
        run {
            await $0.render(progressBase: 0, progressSpan: 100)
            $0.runFinishedAt = Date()
        }
    }

    /// Transcribe, show the words, and produce every export that costs
    /// nothing. The burn deliberately does not follow: dropping a file used
    /// to spend a full re-encode before the user had seen a single word.
    private func transcribeThenOfferExports(modelId: String) async {
        await transcribe(modelId: modelId)
        guard !Task.isCancelled, transcriptionPath != nil else { return }

        loadTranscript()
        // Subtitle-only: ffprobe plus three small files, no encoder. This is
        // what makes .srt reachable without first burning a video.
        await render(progressBase: 0, progressSpan: 100, subtitleOnly: true)
        guard !Task.isCancelled else { return }

        runFinishedAt = Date()
        state = .transcribed
    }

    private func transcribe(modelId: String) async {
        guard let videoURL else { return }

        state = .processing(stage: "starting", percent: 0, message: "Starting...")
        runStartedAt = Date()
        runFinishedAt = nil
        processedMediaSeconds = nil
        totalMediaSeconds = nil
        mediaDuration = (try? await AVURLAsset(url: videoURL).load(.duration).seconds) ?? 0

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

    }

    /// Called when the user switches style after a completed burn.
    func reRender() {
        run { await $0.render(progressBase: 0, progressSpan: 100) }
    }

    /// Bypasses the render cache and asks the backend to redo the current
    /// render from scratch. The cache keys only on settings (style/mode/
    /// broll on-off), not on the b-roll library's contents — so adding or
    /// changing clips after a render already exists at that path wouldn't
    /// otherwise be picked up until the source video's mtime changes.
    func forceRerender() {
        run { await $0.render(progressBase: 0, progressSpan: 100, force: true) }
    }

    /// Step back from a finished burn to the words, without redoing anything.
    func showTranscript() {
        guard hasTranscript else { return }
        state = .transcribed
    }

    /// Every burn goes through here so that Cancel has one thing to cancel.
    private func run(_ body: @escaping (VideoProcessorVM) async -> Void) {
        guard canReRender, !isProcessing else { return }
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }
            await body(self)
        }
    }

    private func render(
        progressBase: Double,
        progressSpan: Double,
        force: Bool = false,
        subtitleOnly: Bool = false
    ) async {
        guard let videoURL, let transcriptionPath = transcriptionPathForRender() else { return }

        let style = selectedStyle.rawValue
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let outputPath = rendersDir
            .appendingPathComponent(baseName + renderSuffix(style: style) + ".mp4").path
        let subtitlePath = (outputPath as NSString).deletingPathExtension + ".ass"

        // Already rendered with these exact settings — reuse instantly.
        // The output path encodes every setting, so a file on disk from a
        // previous session is just as good as this session's cache (the
        // .ass sits next to it; mtime check guards against edited sources).
        if !force, !subtitleOnly,
           serveFromCache(outputPath: outputPath, subtitlePath: subtitlePath, source: videoURL) {
            return
        }

        state = .processing(
            stage: subtitleOnly ? "subtitles" : "rendering",
            percent: progressBase,
            message: subtitleOnly
                ? "Preparing subtitle files..."
                : "Burning \(selectedStyle.displayName) subtitles..."
        )

        let params: [String: Any] = [
            "video_path": videoURL.path,
            "transcription_path": transcriptionPath,
            "style": style,
            "output_path": outputPath,
            "word_mode": wordMode.rawValue,
            "highlight_color": highlightColorHex,
            "broll": brollEnabled,
            "subtitle_only": subtitleOnly
        ]

        for await message in await backend.execute(command: "render", params: params) {
            await MainActor.run {
                switch message.type {
                case "progress":
                    applyProgress(message, base: progressBase, span: progressSpan)
                case "result" where message.success == true:
                    applyRenderResult(message)
                case "error":
                    state = .error(message: message.message ?? "Unknown error")
                default:
                    break
                }
            }
        }
    }

    private func applyProgress(_ message: BackendMessage, base: Double, span: Double) {
        let pct = base + (message.percent ?? 0) / 100 * span
        let msg = message.message ?? ""
        state = .processing(stage: message.stage ?? "", percent: pct, message: msg)
        progressPercent = pct
        progressMessage = msg
        if let processed = message.processedSeconds {
            processedMediaSeconds = processed
            totalMediaSeconds = message.totalSeconds ?? totalMediaSeconds
        }
    }

    private func applyRenderResult(_ message: BackendMessage) {
        // The free exports come back from both kinds of render; the video
        // only from a burn. A subtitle-only pass therefore leaves the state
        // alone rather than claiming a file it never wrote.
        if let sub = message.subtitlePath { subtitleURL = URL(fileURLWithPath: sub) }
        if let srt = message.srtPath { srtURL = URL(fileURLWithPath: srt) }
        if let vtt = message.vttPath { vttURL = URL(fileURLWithPath: vtt) }
        if let lang = message.language { detectedLanguage = lang }
        wordCount = message.wordCount ?? wordCount

        guard let outPath = message.outputPath, let subPath = message.subtitlePath else { return }
        outputURL = URL(fileURLWithPath: outPath)
        keywordsFound = message.keywordsFound ?? 0
        renderCache[outPath] = RenderResult(
            outputPath: outPath,
            subtitlePath: subPath,
            keywordsFound: keywordsFound
        )
        Self.rememberKeywords(keywordsFound, for: outPath)
        state = .done(outputPath: outPath, subtitlePath: subPath)
        onRenderCompleted?()
    }

    func reset() {
        runTask?.cancel()
        runTask = nil
        videoURL = nil
        state = .idle
        outputURL = nil
        subtitleURL = nil
        srtURL = nil
        vttURL = nil
        transcriptionPath = nil
        transcript = nil
        edits = .empty
        unplacedEdits = 0
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
