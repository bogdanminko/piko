import SwiftUI

/// App shell from the design mockup: fixed sidebar navigation on the left,
/// themed content pane on the right. Captions is the working vertical;
/// Library and Meeting Summary are design previews until their backends ship.
struct MainView: View {
    @State private var appState = AppState()
    @State private var processor = VideoProcessorVM()
    @State private var modelManager = ModelManagerVM()
    @State private var summarizer = SummarizerVM()
    @State private var stylePreviews = StylePreviewsVM()
    @State private var history = HistoryStore()
    @State private var meeting = MeetingVM()

    var body: some View {
        let theme = appState.theme
        HStack(spacing: 0) {
            // Top spacing for the hidden-title-bar traffic lights is handled
            // inside the sidebar (the brand row sits beside them).
            SidebarView(appState: appState, modelManager: modelManager,
                        history: history, processor: processor)
                .background { sidebarBackground }

            Rectangle()
                .fill(theme.line)
                .frame(width: 1)
                .ignoresSafeArea()

            screenContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { paneBackground }
        }
        .environment(\.pikoTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.accent)
        .frame(minWidth: 1000, minHeight: 660)
        .task {
            processor.onRenderCompleted = { [weak processor, weak history] in
                guard let processor, let history, let url = processor.videoURL else { return }
                history.record(
                    videoURL: url,
                    style: processor.selectedStyle.displayName,
                    language: processor.detectedLanguage,
                    wordCount: processor.wordCount
                )
            }
            async let models: Void = modelManager.loadModels()
            async let previews: Void = stylePreviews.load()
            // Loaded at launch, not on the Models screen: the summary language
            // picker is built from this list, and it lives on another screen
            // the user may reach first.
            async let tiers: Void = summarizer.loadTiers()
            _ = await (models, previews, tiers)
        }
        // Any subtitle setting changed after a completed run (settings panel
        // or preview screen): fast re-render from the cached transcription —
        // or an instant swap if that combination was already rendered.
        .onChange(of: processor.selectedStyle) { rerenderIfDone() }
        .onChange(of: processor.wordMode) { rerenderIfDone() }
        .onChange(of: processor.highlightColorHex) { rerenderIfDone() }
        .onChange(of: processor.brollEnabled) { rerenderIfDone() }
        // No Generate button: processing starts as soon as a video arrives
        // (drop, file picker, Recent) — or as soon as the model is ready.
        .onChange(of: processor.videoURL) { autoProcess() }
        .onChange(of: modelManager.isSelectedModelDownloaded) { autoProcess() }
        // A finished session doesn't linger: navigating away from (or back
        // to) Captions after the run completed resets to the drop zone.
        // An in-flight run keeps its state; reopening is one click in
        // Recent. Entries opened from Recent arrive in .idle, so they are
        // never swept by this.
        .onChange(of: appState.screen) { oldScreen, newScreen in
            guard oldScreen == .captions || newScreen == .captions else { return }
            switch processor.state {
            case .done, .error:
                processor.reset()
            default:
                break
            }
        }
    }

    private func autoProcess() {
        guard processor.videoURL != nil,
              case .idle = processor.state,
              modelManager.isSelectedModelDownloaded
        else { return }
        Task { await processor.processVideo(modelId: modelManager.selectedModelId) }
    }

    @ViewBuilder
    private var screenContent: some View {
        switch appState.screen {
        case .library:
            LibraryView(appState: appState, processor: processor, history: history)
        case .summary:
            MeetingSummaryView(meeting: meeting, modelId: modelManager.selectedModelId,
                               summarizer: summarizer)
        case .captions:
            CaptionsScreen(
                appState: appState,
                processor: processor,
                modelManager: modelManager,
                stylePreviews: stylePreviews
            )
        case .models:
            ModelsView(modelManager: modelManager, summarizer: summarizer)
        case .appearance:
            AppearanceView(appState: appState)
        }
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        let theme = appState.theme
        if appState.translucent {
            ZStack {
                VisualEffectBackground(material: .sidebar)
                theme.chrome.opacity(0.6)
            }
            .ignoresSafeArea()
        } else {
            theme.chrome.ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var paneBackground: some View {
        let theme = appState.theme
        if appState.translucent {
            ZStack {
                VisualEffectBackground(material: .underWindowBackground)
                theme.pane.opacity(0.8)
            }
            .ignoresSafeArea()
        } else {
            theme.pane.ignoresSafeArea()
        }
    }

    private func rerenderIfDone() {
        if case .done = processor.state {
            Task { await processor.reRender() }
        }
    }
}
