import SwiftUI

/// An artifact where it was produced: a card in the conversation.
///
/// Deliberately small and uniform. It says what was made and how big it is,
/// and clicking it opens the real thing in the panel beside the thread — the
/// card is a handle, not a preview trying to be the artifact. A row of them
/// down a conversation is the session's history without a second list to keep
/// in sync.
struct ArtifactCard: View {
    let artifact: WorkspaceArtifact
    /// One line about what is in it — line count, style, how many action items.
    let detail: String
    /// Whether this is the one currently in the panel. Shown rather than
    /// hidden: clicking an open card again should not look like a dead button.
    var isOpen: Bool
    let onOpen: () -> Void

    @Environment(\.pikoTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 11) {
                Image(systemName: artifact.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.accent)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.13))
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.text)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                Text(isOpen ? "Open" : "Click to open")
                    .font(.system(size: 10.5))
                    .foregroundStyle(isOpen ? theme.accent : theme.dim)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.dim)
            }
            .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? theme.card2 : theme.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isOpen ? theme.accent.opacity(0.6) : theme.line)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - What the session has made

/// The artifacts that currently exist, read off the view models rather than
/// stored. Same rule as the Library: a derived list cannot go stale, and a
/// rerun or a cancelled burn cannot leave a card pointing at nothing.
@MainActor
enum WorkspaceArtifacts {
    static func available(session: ChatSession) -> [WorkspaceArtifact] {
        var list: [WorkspaceArtifact] = []
        if session.processor.hasTranscript { list.append(.transcript) }
        if session.processor.outputURL != nil { list.append(.video) }
        // Read off the *session*, never off `MeetingVM`. That view model is
        // app-level and holds whichever recording is selected, so asking it
        // put a call's transcript and summary in the rail of a conversation
        // that had only ever been given a video — the exact bleed sessions
        // exist to stop, wearing a different hat.
        if session.meetingID != nil {
            list.append(.callTranscript)
            // Offered even before one is written: the panel is where an
            // unwritten summary is asked for, so hiding it until one exists
            // would hide the button that makes one.
            list.append(.callSummary)
        }
        return list
    }

    static func detail(_ artifact: WorkspaceArtifact,
                       session: ChatSession,
                       meeting: MeetingVM) -> String {
        let processor = session.processor
        switch artifact {
        case .transcript:
            let lines = processor.transcript?.lines.count ?? 0
            var parts = ["\(lines) lines"]
            if let language = processor.detectedLanguage, language != "unknown" {
                parts.append(language)
            }
            if processor.editedLineCount > 0 {
                parts.append("\(processor.editedLineCount) edited")
            }
            parts.append("srt · vtt · ass ready")
            return parts.joined(separator: " · ")
        case .video:
            var parts = [processor.selectedStyle.displayName]
            if let rtf = processor.realtimeFactor {
                parts.append(String(format: "%.1f× realtime", rtf))
            }
            return parts.joined(separator: " · ")
        case .callTranscript:
            let segments = meeting.transcript?.segments.count ?? 0
            return "\(segments) lines · each linked to its second"
        case .callSummary:
            guard let summary = meeting.composed, !summary.isEmpty else {
                return "not written yet"
            }
            return "\(summary.actionItems.count) action items · "
                + "\(summary.decisions.count) decisions"
        }
    }
}
