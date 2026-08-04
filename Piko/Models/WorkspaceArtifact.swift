import Foundation

/// Something the session has produced that is worth opening on its own.
///
/// The thread is the record of what happened, so a result belongs *in* it — but
/// as a card, not as the thing itself. A transcript of four hundred lines
/// cannot live inside a chat bubble, and a panel permanently docked under the
/// conversation is a split window pretending to be a message: two halves of one
/// screen, each too short to read.
///
/// So the card in the thread is a **handle**. Opening one puts the full
/// artifact in a panel beside the conversation, which is closable, and which
/// shows one artifact at a time chosen from everything this session has made.
/// The chat keeps its full height whether or not anything is open.
enum WorkspaceArtifact: String, Identifiable, Hashable, CaseIterable {
    /// A clip's words, correctable, with the free subtitle files beside them.
    case transcript
    /// The burned render.
    case video
    /// A call's words, with the side that said each line.
    case callTranscript
    /// Brief, decisions and action items, with everywhere they can be sent.
    case callSummary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcript: return "Transcript"
        case .video: return "Styled video"
        case .callTranscript: return "Transcript"
        case .callSummary: return "Summary"
        }
    }

    var icon: String {
        switch self {
        case .transcript, .callTranscript: return "text.alignleft"
        case .video: return "film"
        case .callSummary: return "list.bullet.rectangle"
        }
    }
}
