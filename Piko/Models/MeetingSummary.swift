import Foundation

/// A finished meeting summary, as `summarize_meeting` returns it.
///
/// Every item carries `start` in seconds rather than a formatted timecode:
/// the backend resolves citations to real transcript positions
/// (src/piko/skills/meeting/summary.py), and seconds are what seeking needs.
/// Formatting for display belongs to the view.
struct MeetingSummary: Codable, Hashable {
    /// Two or three sentences: what the meeting settled.
    let brief: String
    /// The long read — how the discussion actually went. Shown behind Expand.
    let summary: String
    let topics: [String]
    let decisions: [Item]
    let actionItems: [Item]
    let openQuestions: [Item]
    let language: String?

    /// One cited claim. `owner` and `due` are only ever set for action items,
    /// and only when someone actually said them.
    struct Item: Codable, Hashable, Identifiable {
        let text: String
        let start: Double
        let owner: String?
        let due: String?

        /// Stable within a summary: no two items share a position and a text.
        var id: String { "\(start)-\(text)" }
    }

    enum CodingKeys: String, CodingKey {
        case brief, summary, topics, decisions, language
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    var isEmpty: Bool {
        brief.isEmpty && decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty
    }
}
