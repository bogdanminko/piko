import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The workspace: one recording and whatever can be got out of it.
///
/// This replaces the two tabs the app used to open with. Two entrances meant
/// declaring what kind of work this was before anything had looked at the
/// file — and one product reading as two. The pipeline is picked from the file
/// itself; a wrong guess costs one click, not a restart.
struct ArtifactScreen: View {
    @Bindable var appState: AppState
    @Bindable var store: SessionStore
    /// The conversation on screen. Its thread, its captions run and where the
    /// reader had the panel all travel together — that is what stopped one
    /// session's artifacts turning up in another's.
    @Bindable var session: ChatSession
    @Bindable var modelManager: ModelManagerVM
    @Bindable var meeting: MeetingVM
    @Bindable var summarizer: SummarizerVM
    var stylePreviews: StylePreviewsVM
    /// The window's one file panel, owned by `MainView`. The argument forces a
    /// pipeline: `/captions` means captions even for a fifty-minute file, which
    /// the metadata guess would otherwise read as a call.
    var onOpenFile: (ArtifactFocus?) -> Void

    /// Always the conversation. The workspace used to switch to a module screen
    /// the moment anything was loaded — drop a video and you were on a
    /// transcriber, open a call from Library and you were on a summary page —
    /// which is how one product went back to reading as several. Modules are
    /// not screens any more: they are what the artifact panel expands into.
    var body: some View {
        ArtifactEntry(appState: appState, store: store, session: session,
                      modelManager: modelManager, meeting: meeting,
                      summarizer: summarizer,
                      stylePreviews: stylePreviews, onOpenFile: onOpenFile)
    }
}

// MARK: - The way in

/// One drop target for anything with speech in it, and one button for the
/// thing no file can start: recording a call that is happening now.
struct ArtifactEntry: View {
    @Bindable var appState: AppState
    @Bindable var store: SessionStore
    @Bindable var session: ChatSession
    @Bindable var modelManager: ModelManagerVM
    @Bindable var meeting: MeetingVM

    @Bindable var summarizer: SummarizerVM
    var stylePreviews: StylePreviewsVM
    /// Opens the one file panel the app has, which lives in `MainView`.
    /// A second `.fileImporter` in the same window silently loses the race
    /// with the first — which is why this button did nothing at all.
    var onOpenFile: (ArtifactFocus?) -> Void

    @Environment(\.pikoTheme) private var theme

    var chat: WorkspaceChatVM { session.chat }
    var processor: VideoProcessorVM { session.processor }
    /// The artifact open beside the thread, and whether it is expanded. Both
    /// live on the session rather than in `@State`: coming back to a
    /// conversation should come back to where you were in it.
    private var openArtifact: WorkspaceArtifact? { session.openArtifact }
    private var isPanelExpanded: Bool { session.isPanelExpanded }

    private var artifacts: [WorkspaceArtifact] {
        WorkspaceArtifacts.available(session: session)
    }

    /// What this conversation has to play, if anything.
    private var audioURL: URL? {
        ArtifactPlayer.audioURL(for: session, meeting: meeting)
    }

    /// Enough to read a transcript in, never more than the chat beside it. The
    /// window's floor is 1000 pt wide and the sidebar takes its share, so the
    /// clamp is what stops the conversation being squeezed to a column of
    /// broken words on a small display.
    private func panelWidth(_ paneWidth: CGFloat) -> CGFloat {
        min(max(paneWidth * 0.42, 360), 560)
    }

    /// A shortcut does the thing rather than describing it. Every one of them
    /// lands somewhere that already exists — nothing here is a stub.
    private func run(_ command: ChatCommand) {
        switch command.name {
        // Asked for by name, so the metadata guess does not get a vote: an
        // hour-long screen share is a call when it is dropped and a thing to
        // caption when somebody typed `/captions`.
        case "/captions": onOpenFile(.video)
        case "/summarize": onOpenFile(.meeting)
        case "/record": startRecording()
        case "/library": appState.screen = .library
        default: chat.send("What can you do?")
        }
    }

    private func startRecording() {
        appState.wantsRecorder = true
        guard !meeting.recorder.isActive else { return }
        Task {
            await meeting.toggleRecording(model: modelManager.selectedModelId,
                                          diarize: modelManager.diarizationReady)
        }
    }

    var body: some View {
        layout
            // Published above both halves, so a timecode the model quoted in
            // the thread goes to the same place as one in the transcript. The
            // panel does not own this: a citation is followable whether or not
            // the artifact happens to be open.
            .environment(\.seekToTime, audioURL == nil ? nil : { session.player.seek(to: $0) })
            .onAppear {
                session.player.load(audioURL)
                spendPendingSeek()
            }
            .onChange(of: audioURL) { _, url in
                session.player.load(url)
                spendPendingSeek()
            }
            .onChange(of: session.pendingSeek) { _, _ in spendPendingSeek() }
    }

    private var layout: some View {
        GeometryReader { geo in
            if isPanelExpanded, openArtifact != nil {
                panel.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    chatColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if openArtifact != nil {
                        Rectangle().fill(theme.line).frame(width: 1)
                        panel
                            .frame(width: panelWidth(geo.size.width))
                            .background(theme.card.opacity(0.35))
                    }
                }
            }
        }
        // A finished artifact is announced in the thread and pulled up beside
        // it in the same breath. Producing something and leaving the reader to
        // find it is the failure mode a docked panel was covering for.
        .onChange(of: processor.state) { _, state in
            if case .transcribed = state {
                chat.jobFinished(.transcript, text: "Transcribed. The lines are in the "
                    + "transcript — click one to correct it, or save the subtitle files.")
                show(.transcript)
            }
            if case .done = state {
                chat.jobFinished(.result, text: "Burned in.")
                show(.video)
            }
        }
        .onChange(of: meeting.transcript?.segments.count) { _, count in
            guard count != nil else { return }
            chat.jobFinished(.meeting, text: "The recording is transcribed.")
            show(.callTranscript)
        }
        .onChange(of: meeting.composed?.isEmpty) { _, isEmpty in
            guard isEmpty == false else { return }
            show(.callSummary)
        }
        // An artifact that no longer exists must not stay on screen: a reset,
        // a cancelled burn or a different recording would otherwise leave the
        // panel showing something the session no longer has.
        .onChange(of: artifacts) { _, list in
            guard let open = openArtifact, !list.contains(open) else { return }
            // Mid-load the artifact is on its way, and closing the panel under
            // somebody who just opened a recording is worse than an empty card
            // for a second. Only a session holding nothing at all closes.
            if processor.videoURL == nil, session.meetingID == nil { close() }
        }
        // Something opened from anywhere at all — Library, Recent, a `piko://`
        // link, the sidebar's New menu — arrives here rather than on a screen
        // of its own. This is the one place that turns "a call is loaded" into
        // "the call is open beside the conversation".
        .onChange(of: appState.focus) { _, focus in openFor(focus) }
        // Kept current so the model never tells somebody to drop a file that
        // is already open, and so a typed request can be carried out instead
        // of described.
        .onAppear {
            chat.onIntent = handle
            chat.context = chatContext
            chat.artifact = artifactText
            chat.modelTier = summarizer.selectedTier
        }
        .onChange(of: chatContext) { _, value in chat.context = value }
        .onChange(of: artifactText) { _, value in chat.artifact = value }
        .onChange(of: summarizer.selectedTier) { _, tier in chat.modelTier = tier }
    }

    /// The way back to what this session made.
    ///
    /// The panel closes, and until now closing it was one-way: the only handle
    /// left was the card in the thread, which is fine for a minute and useless
    /// once the conversation has moved on past it. A result you cannot get back
    /// to without scrolling for it is a result the session has mislaid.
    @ViewBuilder
    private var artifactToggle: some View {
        if !artifacts.isEmpty {
            HStack(spacing: 7) {
                if openArtifact == nil, artifacts.count > 1 {
                    Text("\(artifacts.count) artifacts")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                }
                PanelToggleButton(
                    icon: openArtifact == nil ? "sidebar.right" : "sidebar.trailing",
                    help: openArtifact == nil
                        ? "Show what this session made"
                        : "Hide the artifact"
                ) {
                    // Reopens on the newest thing the session produced; the
                    // rail inside the panel is where a different one is picked.
                    if openArtifact == nil {
                        if let newest = artifacts.last { show(newest) }
                    } else {
                        close()
                    }
                }
            }
        }
    }

    private var panel: some View {
        ArtifactSidePanel(appState: appState,
                          player: session.player,
                          hasAudio: audioURL != nil,
                          processor: processor,
                          modelManager: modelManager,
                          meeting: meeting,
                          summarizer: summarizer,
                          stylePreviews: stylePreviews,
                          artifacts: artifacts,
                          open: $session.openArtifact,
                          isExpanded: $session.isPanelExpanded,
                          onBurn: { chat.openStyles() })
    }

    /// Follow a `piko://…?t=` link, once there is something to follow it into.
    private func spendPendingSeek() {
        guard let seconds = session.pendingSeek, audioURL != nil else { return }
        session.pendingSeek = nil
        session.player.seek(to: seconds)
    }

    /// Pull an artifact up beside the thread.
    private func show(_ artifact: WorkspaceArtifact) {
        withAnimation(.easeInOut(duration: 0.2)) { session.openArtifact = artifact }
    }

    /// Closing takes the expansion with it: leaving `isPanelExpanded` set means
    /// the next artifact opens full-width over a conversation nobody asked to
    /// leave.
    private func close() {
        withAnimation(.easeInOut(duration: 0.2)) {
            session.openArtifact = nil
            session.isPanelExpanded = false
        }
    }

    /// What a loaded artifact means for the panel.
    ///
    /// Only opens what actually exists yet. A video just handed over has a run
    /// in the thread and nothing to read, so the panel stays shut until the
    /// transcript lands — announcing an artifact before there is one is the
    /// same lie as a progress bar with invented lines in it.
    private func openFor(_ focus: ArtifactFocus) {
        switch focus {
        case .none:
            close()
        case .meeting:
            guard session.meetingID != nil else { return }
            show(meeting.composed?.isEmpty == false ? .callSummary : .callTranscript)
        case .video:
            guard processor.hasTranscript else { return }
            show(processor.outputURL != nil ? .video : .transcript)
        }
    }

    private var chatColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Titled after the conversation, not after the app. "Reopen" used
            // to live here because there was one session and no way back into
            // it once you had wandered off; the sidebar lists the chats now, so
            // going back is where going anywhere already is.
            ScreenHeader(title: session.title,
                         subtitle: subtitleLine,
                         accessory: { artifactToggle })
            // Stop lives here while a call is being recorded, so leaving the
            // conversation is never the price of controlling the recorder.
            if appState.wantsRecorder || meeting.recorder.isActive {
                RecordingBar(
                    recorder: meeting.recorder,
                    permissions: meeting.permissions,
                    onToggle: {
                        Task {
                            await meeting.toggleRecording(
                                model: modelManager.selectedModelId,
                                diarize: modelManager.diarizationReady)
                        }
                    },
                    onPauseToggle: meeting.togglePause
                )
            }
            // The conversation *is* the way in. A drop panel beside it was a
            // second answer to the same question, and it made the assistant a
            // liar the moment it said "drop the file here" — which it does,
            // because that is what anyone would expect of a chat.
            // One playhead, always visible, and it never moves house: beside
            // the composer while the conversation is on screen, and up in the
            // expanded panel's strip when it is not.
            if audioURL != nil, !isPanelExpanded {
                PlayerBar(player: session.player)
            }
            WorkspaceChatView(
                session: session,
                meeting: meeting,
                summarizer: summarizer,
                previews: stylePreviews,
                isModelReady: summarizer.isModelDownloaded,
                isModelWarm: summarizer.isModelWarm,
                warmupSeconds: summarizer.warmupSeconds,
                onWarmup: { summarizer.warmup() },
                onCommand: run,
                onAttach: { onOpenFile(nil) },
                onDropFile: accept,
                onRecord: startRecording,
                openArtifact: openArtifact,
                onOpenArtifact: show
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
    }

    /// Take the file and start work — without going anywhere.
    ///
    /// Nothing here changes the screen. The file appears in the thread, the
    /// pipeline starts behind it, and its progress and result are rendered as
    /// cards in the same conversation. Being thrown onto another screen the
    /// moment you hand something over is what made the chat feel like a form
    /// rather than the place the work happens.
    private func accept(_ url: URL) {
        close()
        Task { @MainActor in
            await ArtifactRouting.open(url, into: workspace)
        }
    }

    /// What the model can read, as opposed to what it is told exists.
    ///
    /// The summary when there is one — it is the short read and the one a
    /// question is usually about — otherwise the words themselves. Empty when
    /// the session holds nothing, so an idle chat costs no context at all.
    private var artifactText: String {
        if session.meetingID != nil, let recording = meeting.selected {
            if let summary = meeting.composed, !summary.isEmpty {
                return MarkdownExport.make(summary, for: recording)
            }
            if let transcript = meeting.transcript {
                return MarkdownExport.transcript(transcript)
            }
        }
        return processor.transcript?.plainText ?? ""
    }

    /// What this conversation is about, in one line. Says the state rather
    /// than describing the product: an empty session and a loaded one look
    /// identical without it.
    private var subtitleLine: String {
        if let url = processor.videoURL {
            return url.lastPathComponent
        }
        if let recording = meeting.selected, session.meetingID == recording.id {
            return "Recorded call"
        }
        return "Anything with speech in it, turned into text you own"
    }

    private var workspace: Workspace {
        Workspace(appState: appState, store: store,
                  meeting: meeting, modelManager: modelManager)
    }
}
