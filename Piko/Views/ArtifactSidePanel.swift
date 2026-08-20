import SwiftUI

/// The artifact, open beside the conversation.
///
/// One panel, one artifact, and a rail across the top listing everything this
/// session has made so any of them can be pulled up without scrolling back
/// through the thread. It closes, and closing it gives the whole width back to
/// the chat — which is the difference between a panel and a second screen.
///
/// Nothing in here is new: each artifact renders the view that already existed
/// for it. The panel decides *which* one is showing and nothing else.
struct ArtifactSidePanel: View {
    @Bindable var appState: AppState
    @Bindable var player: ArtifactPlayer
    /// Whether there is anything to play. The bar is drawn here only while the
    /// panel is expanded — the rest of the time it lives beside the composer,
    /// so there is exactly one playhead on screen and it never moves house.
    let hasAudio: Bool
    @Bindable var processor: VideoProcessorVM
    @Bindable var modelManager: ModelManagerVM
    @Bindable var meeting: MeetingVM
    @Bindable var summarizer: SummarizerVM
    var stylePreviews: StylePreviewsVM
    /// Everything the session has produced, newest reading first.
    let artifacts: [WorkspaceArtifact]
    /// Which one is showing. Nil closes the panel.
    @Binding var open: WorkspaceArtifact?
    /// Taken full-width, where the artifact's whole module is rendered instead
    /// of the compact reading.
    @Binding var isExpanded: Bool
    /// Ask for the style controls, which live in the thread rather than here:
    /// choosing a look is a step in the conversation, not a property of a
    /// finished artifact.
    var onBurn: () -> Void

    @Environment(\.pikoTheme) private var theme

    /// Expanded, the panel *is* the module — `CaptionsScreen` and
    /// `MeetingSummaryView` in full, with their own header, settings rail and
    /// recordings list. Those screens were the app before the workspace was,
    /// and the work in them is real; what was wrong was arriving at them
    /// instead of at the session. As the far end of one panel they are what a
    /// reader asked for rather than where a file was sent.
    var body: some View {
        if isExpanded, let open {
            VStack(spacing: 0) {
                expandedBar
                if hasAudio {
                    PlayerBar(player: player)
                        .padding(EdgeInsets(top: 10, leading: 26, bottom: 0, trailing: 26))
                }
                module(open)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let open {
                    reading(open)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 22, leading: 18, bottom: 22, trailing: 22))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The way back, above a module that has a header of its own. Deliberately
    /// its own strip rather than a button squeezed into that header: the module
    /// header names the artifact, this one names where you are.
    private var expandedBar: some View {
        HStack(spacing: 9) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded = false }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Back to the conversation")
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(theme.dim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the conversation")
            Spacer()
            if artifacts.count > 1 {
                FlowLayout(spacing: 6) {
                    ForEach(artifacts) { artifact in
                        railButton(artifact)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 26, bottom: 12, trailing: 26))
        .background(theme.card.opacity(0.4))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    /// Which module a given artifact belongs to. Two readings of a call share
    /// one screen, as do a clip's transcript and its burned copy.
    @ViewBuilder
    private func module(_ artifact: WorkspaceArtifact) -> some View {
        switch artifact {
        case .transcript, .video:
            CaptionsScreen(appState: appState, processor: processor,
                           modelManager: modelManager, meeting: meeting,
                           stylePreviews: stylePreviews, embedded: true)
        case .callTranscript, .callSummary:
            MeetingSummaryView(appState: appState,
                               meeting: meeting,
                               modelId: modelManager.selectedModelId,
                               diarize: modelManager.diarizationReady,
                               summarizer: summarizer,
                               embedded: true)
        }
    }

    // MARK: - What is showing, and what else there is

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Text(open?.title ?? "Artifact")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                if let name = sourceName {
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                // A transcript to correct and a burn to set up want the window,
                // not a column beside a chat. Expanding is not navigating —
                // the conversation is exactly where it was, one click away.
                PanelToggleButton(icon: "arrow.up.left.and.arrow.down.right",
                                  help: "Expand to the full window") {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded = true }
                }
                PanelToggleButton(icon: "xmark", help: "Close the artifact") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        open = nil
                        isExpanded = false
                    }
                }
            }

            // The session's other artifacts. Only drawn when there is a choice
            // to make — a rail with one item on it is furniture.
            if artifacts.count > 1 {
                FlowLayout(spacing: 6) {
                    ForEach(artifacts) { artifact in
                        railButton(artifact)
                    }
                }
            }

            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    private func railButton(_ artifact: WorkspaceArtifact) -> some View {
        let isOn = open == artifact
        return Button {
            open = artifact
        } label: {
            HStack(spacing: 5) {
                Image(systemName: artifact.icon)
                    .font(.system(size: 9.5))
                Text(railTitle(artifact))
                    .font(.system(size: 11))
            }
            .foregroundStyle(isOn ? theme.accent : theme.dim)
            .padding(EdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 10))
            .background {
                Capsule().fill(theme.accent.opacity(isOn ? 0.15 : 0))
                    .overlay { Capsule().strokeBorder(isOn ? .clear : theme.line) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A clip and a call both call their words "Transcript", and both can be in
    /// one session — the rail says which is which rather than showing the same
    /// word twice.
    private func railTitle(_ artifact: WorkspaceArtifact) -> String {
        switch artifact {
        case .callTranscript where processor.hasTranscript: return "Call transcript"
        case .transcript where meeting.transcript != nil: return "Clip transcript"
        default: return artifact.title
        }
    }

    private var sourceName: String? {
        switch open {
        case .transcript, .video: return processor.videoURL?.lastPathComponent
        case .callTranscript, .callSummary: return meeting.selected?.title
        case .none: return nil
        }
    }

    @ViewBuilder
    private func reading(_ artifact: WorkspaceArtifact) -> some View {
        switch artifact {
        case .transcript:
            TranscriptView(processor: processor, onBurn: onBurn)
        case .video:
            ChatResultCard(processor: processor)
        case .callTranscript:
            ChatMeetingTranscriptCard(meeting: meeting)
        case .callSummary:
            MeetingSummaryColumn(meeting: meeting,
                                 summarizer: summarizer,
                                 params: summarizer.requestParams)
        }
    }
}
