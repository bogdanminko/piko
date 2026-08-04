import SwiftUI
import UniformTypeIdentifiers

/// The workspace before it has been given anything: a conversation that
/// explains the app, and a drop target underneath it.
///
/// Chat is the shape people arrive already knowing how to use, so it carries
/// the explaining. It is not, however, an open-ended assistant: the composer
/// stays shut until the app has said what it does, the shortcuts are a fixed
/// list, and every answer is grounded in one capability sheet that lives in
/// `src/piko/commands/chat.py`.
///
/// The design decision worth keeping: the first answer is written rather than
/// generated, and **says so on the turn itself**. A canned reply passed off as
/// the model's is a small lie that costs trust the moment somebody notices;
/// the same reply, labelled, is a stated design choice with a visible reason.
struct WorkspaceChatView: View {
    /// The conversation this view *is*. Its thread and its captions run travel
    /// together, so a card can never be about work another session did.
    @Bindable var session: ChatSession
    @Bindable var meeting: MeetingVM
    @Bindable var summarizer: SummarizerVM
    /// Rendered style strips, so choosing a look in the thread shows the same
    /// picture the burn will produce.
    var previews: StylePreviewsVM
    var isModelReady: Bool
    var isModelWarm: Bool
    var warmupSeconds: Double?
    var onWarmup: () -> Void
    var onCommand: (ChatCommand) -> Void
    /// Open the file panel — the same one the drop target feeds.
    var onAttach: () -> Void
    /// A file handed over in the conversation.
    var onDropFile: (URL) -> Void
    var onRecord: () -> Void
    /// Which artifact the panel beside the thread is showing, if any. The cards
    /// mark themselves open rather than looking like dead buttons.
    var openArtifact: WorkspaceArtifact?
    /// Pull an artifact up in that panel.
    var onOpenArtifact: (WorkspaceArtifact) -> Void

    @Environment(\.pikoTheme) var theme
    var chat: WorkspaceChatVM { session.chat }
    var processor: VideoProcessorVM { session.processor }
    @State private var isTargeted = false
    @State var showsSlashPanel = false
    /// The ⌘V watcher, kept so it can be torn down with the view.
    @State var pasteMonitor: Any?
    @FocusState var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            conversation
            if showsSlashPanel || !chat.commandSuggestions.isEmpty {
                slashPanel
            }
            // Where a hint belongs: next to the thing it is a hint for. Two
            // buttons stranded in the middle of an empty card were an
            // instruction to look somewhere other than the box you are about to
            // type in.
            if chat.turns.isEmpty { starters }
            composer
        }
    }

    // MARK: - Starters

    /// What you can ask for, as things you can press.
    ///
    /// Every one of them *does* the thing rather than describing it, and none
    /// of them is a toll: the composer is open from the first frame, so these
    /// are for the person who does not yet know what to type, not a gate in
    /// front of the person who does.
    private var starters: some View {
        FlowLayout(spacing: 7) {
            starter("What can you do?", icon: "sparkles") {
                chat.askWhatItCanDo(warmup: onWarmup)
            }
            starter("Add a video or a call", icon: "paperclip", action: onAttach)
            starter("Record a call", icon: "mic", action: onRecord)
            starter("Past sessions", icon: "square.grid.2x2") {
                if let library = ChatCommand.all.first(where: { $0.name == "/library" }) {
                    onCommand(library)
                }
            }
        }
    }

    private func starter(_ title: String,
                         icon: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
            }
            .padding(EdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 13))
            .background {
                Capsule().fill(theme.card2)
                    .overlay { Capsule().strokeBorder(theme.line) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Conversation

    /// The conversation is the drop target. Telling somebody to drag a file
    /// "here" and then not taking it is the one thing an assistant must not
    /// do, and it is what a separate drop panel off to the side amounted to.
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.turns) { turn in
                        turnView(turn).id(turn.id)
                    }
                }
                .padding(EdgeInsets(top: 18, leading: 18, bottom: 10, trailing: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // An empty thread is not a page with nothing on it — it is one
            // sentence, sitting where the first answer will.
            .overlay { if chat.turns.isEmpty { opening } }
            // A landing token is not a new turn. Animating to the same anchor
            // thirty times a second is a scroll animation fighting itself, and
            // it is most of what "the scrolling is not smooth" was.
            .onChange(of: chat.turns.last?.text) { scroll(proxy, animated: false) }
            .onChange(of: chat.turns.count) { scroll(proxy, animated: true) }
            // The cost line arrives *after* the last token and adds height
            // below it, so a thread that was pinned to the bottom while the
            // answer streamed ends up one line short of it — and the numbers
            // you asked for are the one thing you then have to scroll to find.
            .onChange(of: chat.turns.last?.stats) { scroll(proxy, animated: false) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface(theme)
        .overlay { if isTargeted { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in load(providers) }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = chat.turns.last else { return }
        guard animated else {
            proxy.scrollTo(last.id, anchor: .bottom)
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
            .background { RoundedRectangle(cornerRadius: 10).fill(theme.accent.opacity(0.07)) }
            .overlay {
                Text("Drop it in")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
    }

    /// The only thing that can be said first. One question, asked for you —
    /// the alternative is an empty box in front of somebody who has no way of
    /// knowing what to type into it.
    private var opening: some View {
        VStack(spacing: 9) {
            Text("Drop a file, or just ask.")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Video, audio or a recording of a call. Everything runs on this "
                 + "Mac — there is no upload and no account.")
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.dim)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .allowsHitTesting(false)
    }

    // MARK: - One turn

    @ViewBuilder
    private func turnView(_ turn: ChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ChatBubble(turn: turn)
            if turn.showsCapabilityCards, !turn.isStreaming {
                capabilityCards
                provenanceStrip
                if isModelWarm { followUps }
            }
            payload(turn.payload)
        }
    }

    /// Work rendered where it was asked for.
    ///
    /// Two kinds of thing land in a thread, and they are not the same kind. A
    /// run in progress and a choice being offered are *moments* — they belong
    /// inline, at full size, because that is what the conversation is about
    /// right now. A finished result is an **artifact**: it gets a card, and the
    /// card opens it in the panel. Putting four hundred transcript lines in a
    /// bubble is how a chat stops being one.
    @ViewBuilder
    private func payload(_ payload: ChatTurn.Payload) -> some View {
        switch payload {
        case .none, .exports:
            EmptyView()
        case .job:
            ChatJobCard(processor: processor)
        case .transcript:
            VStack(alignment: .leading, spacing: 8) {
                artifactCard(.transcript)
                Button("Style & burn in…") { chat.openStyles() }
                    .buttonStyle(GhostButtonStyle())
                    .controlSize(.small)
            }
        case .styles:
            ChatStyleCard(processor: processor, previews: previews)
        case .burning:
            ChatBurnProgressCard(processor: processor)
        case .result:
            artifactCard(.video)
        case .meeting:
            VStack(alignment: .leading, spacing: 8) {
                artifactCard(.callTranscript)
                artifactCard(.callSummary)
            }
        }
    }

    private func artifactCard(_ artifact: WorkspaceArtifact) -> some View {
        ArtifactCard(
            artifact: artifact,
            detail: WorkspaceArtifacts.detail(artifact, session: session, meeting: meeting),
            isOpen: openArtifact == artifact,
            onOpen: { onOpenArtifact(artifact) }
        )
    }

    // MARK: - Drops

    /// Finder registers a dragged file only as `public.file-url`; asking for
    /// `.movie` declines the drop before it begins.
    private func load(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            let url: URL?
            switch item {
            case let value as URL: url = value
            case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
            default: url = nil
            }
            guard let url else { return }
            Task { @MainActor in onDropFile(url) }
        }
        return true
    }
}
