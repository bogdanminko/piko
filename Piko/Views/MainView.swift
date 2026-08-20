import AppKit
import SwiftUI

/// App shell from the design mockup: fixed sidebar navigation on the left,
/// themed content pane on the right. Captions and Meeting Summary are the
/// working verticals; Library is the history over both of them.
struct MainView: View {
    @State private var appState = AppState()
    @State private var store = SessionStore()
    @State private var modelManager = ModelManagerVM()
    @State private var summarizer = SummarizerVM()
    @State private var stylePreviews = StylePreviewsVM()
    @State private var history = HistoryStore()
    @State private var meeting = MeetingVM()
    /// Opened from the sidebar's New menu, so a file can be brought in from
    /// any screen rather than only from the workspace's drop zone.
    @State private var isImporterPresented = false
    /// The pipeline the request named, if it named one. `/captions` on a
    /// fifty-minute file must stay captions; the metadata guess reads anything
    /// that long as a call, which is right for a drop and wrong for an order.
    @State private var pendingFocus: ArtifactFocus?

    /// The conversation on screen, and the captions run that belongs to it.
    /// Per session, so an artifact can never turn up in a thread that did not
    /// make it.
    private var session: ChatSession { store.current }
    private var processor: VideoProcessorVM { session.processor }

    private var workspace: Workspace {
        Workspace(appState: appState, store: store,
                  meeting: meeting, modelManager: modelManager)
    }

    var body: some View {
        let theme = appState.theme
        HStack(spacing: 0) {
            // Top spacing for the hidden-title-bar traffic lights is handled
            // inside the sidebar (the brand row sits beside them).
            SidebarView(appState: appState, store: store, modelManager: modelManager,
                        summarizer: summarizer, onNewSession: newSession)
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
            store.onCreate = { [history] session in wire(session, history: history) }
            wire(session, history: history)
            async let models: Void = modelManager.loadModels()
            async let previews: Void = stylePreviews.load()
            // Loaded at launch, not on the Models screen: the summary language
            // picker is built from this list, and it lives on another screen
            // the user may reach first.
            async let tiers: Void = summarizer.loadTiers()
            _ = await (models, previews, tiers)
        }
        // A task exported to Reminders carries `piko://meeting/<id>?t=…` — the
        // link that keeps it verifiable after it has left the app. Following
        // one now opens that meeting *and plays from that second*: the
        // timestamp has been in every exported task since the beginning and
        // there was nothing to spend it on until the player existed.
        .onOpenURL { url in
            guard let link = PikoURL.parse(url),
                  let recording = meeting.recordings.first(where: { $0.id == link.recordingID })
            else { return }
            ArtifactRouting.open(LibraryItem(meeting: recording), into: workspace)
            store.current.pendingSeek = link.seconds
        }
        // Any subtitle setting changed after a completed run (settings panel
        // or preview screen): fast re-render from the cached transcription —
        // or an instant swap if that combination was already rendered.
        .onChange(of: processor.selectedStyle) { rerenderIfDone() }
        .onChange(of: processor.wordMode) { rerenderIfDone() }
        .onChange(of: processor.highlightColorHex) { rerenderIfDone() }
        .onChange(of: processor.brollEnabled) { rerenderIfDone() }
        // Transcription starts as soon as a video arrives (drop, file picker,
        // Recent) — or as soon as the model is ready. It is fast and free.
        // The burn does not follow: that costs a full re-encode and waits to
        // be asked for on the transcript screen.
        .onChange(of: processor.videoURL) {
            autoProcess()
            store.scheduleSave(session)
        }
        .onChange(of: modelManager.isSelectedModelDownloaded) { autoProcess() }
        .onChange(of: store.currentID) { syncMeeting() }
        .modifier(SessionSaving(store: store, session: session))
        .onChange(of: meeting.selectedID) { _, id in
            session.meetingID = id
            // A call recorded in this conversation names it. Nothing else can:
            // a recording is titled after its clock time, which is exactly the
            // name a list of them cannot be read by.
            if let recording = meeting.selected, recording.id == id {
                session.name(recording.title)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            // .data keeps the panel open to anything: the real compatibility
            // list is whatever ffmpeg can decode, not what macOS has a UTType for.
            allowedContentTypes: [.audiovisualContent, .audio, .movie, .data]
        ) { result in
            let decided = pendingFocus
            pendingFocus = nil
            guard case .success(let url) = result else { return }
            Task { await ArtifactRouting.open(url, as: decided, into: workspace) }
        }
        // Deliberately no sweep on navigation. The old Captions tab reset
        // itself whenever you left it, which was defensible when a screen was
        // a mode; in a workspace the open artifact *is* the state, and a walk
        // to Library and back must not throw away a finished render or an
        // unsaved correction.
    }

    /// A conversation is born in exactly one place, so the shell wiring it
    /// needs is attached in exactly one place too.
    private func wire(_ session: ChatSession, history: HistoryStore) {
        session.processor.onRenderCompleted = { [weak history] in
            let processor = session.processor
            guard let history, let url = processor.videoURL else { return }
            history.record(
                videoURL: url,
                style: processor.selectedStyle.displayName,
                language: processor.detectedLanguage,
                wordCount: processor.wordCount
            )
        }
    }

    private func newSession() {
        store.newSession()
        appState.wantsRecorder = false
        appState.screen = .artifact
        appState.show(.none)
    }

    /// One recorder and one folder of recordings on this Mac, so the meeting
    /// library is app-level; which recording is *selected* is per session, and
    /// this is the seam. Switching conversations reselects; anything that
    /// selects — finishing a recording, an import — writes back.
    private func syncMeeting() {
        let wanted = session.meetingID
        guard meeting.selectedID != wanted else { return }
        meeting.select(meeting.recordings.first { $0.id == wanted })
    }

    private func openImporter(as focus: ArtifactFocus?) {
        pendingFocus = focus
        isImporterPresented = true
    }

    private func autoProcess() {
        guard processor.videoURL != nil,
              case .idle = processor.state,
              modelManager.isSelectedModelDownloaded
        else { return }
        processor.start(modelId: modelManager.selectedModelId)
    }

    @ViewBuilder
    private var screenContent: some View {
        switch appState.screen {
        case .library:
            LibraryView(workspace: workspace, history: history)
        case .artifact:
            ArtifactScreen(
                appState: appState,
                store: store,
                session: session,
                modelManager: modelManager,
                meeting: meeting,
                summarizer: summarizer,
                stylePreviews: stylePreviews,
                onOpenFile: openImporter(as:)
            )
            .id(session.id)
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
            processor.reRender()
        }
    }
}

/// When a conversation is written out.
///
/// Extracted from `MainView.body` for the compiler's sake — a dozen more
/// `onChange`s in one expression pushes SwiftUI's type checker past its budget
/// and the build fails with a timeout rather than an error you can read.
///
/// The debounce inside `scheduleSave` is what makes it safe to watch a
/// streaming answer here: the last turn's text changes per token, and one disk
/// write per token is a document nobody is reading yet, written thirty times a
/// second.
private struct SessionSaving: ViewModifier {
    let store: SessionStore
    let session: ChatSession

    func body(content: Content) -> some View {
        content
            .onChange(of: session.chat.turns.count) { store.scheduleSave(session) }
            .onChange(of: session.chat.turns.last?.text) { store.scheduleSave(session) }
            .onChange(of: session.title) { store.scheduleSave(session) }
            .onChange(of: session.meetingID) { store.scheduleSave(session) }
            .onChange(of: session.openArtifact) { store.scheduleSave(session) }
            .onChange(of: session.isPanelExpanded) { store.scheduleSave(session) }
            // Quitting is the one moment a debounce would never fire.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification)) { _ in store.saveAll() }
    }
}
