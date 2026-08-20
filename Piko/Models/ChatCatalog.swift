import Foundation

// What the workspace offers, as data rather than prose. Both the cards and
// the slash list are kept in step with the capability sheet the model reads
// (`CAPABILITIES` in src/piko/commands/chat.py) — one answer, two renderings.

/// One thing Piko can do, with what each way out of it costs.
///
/// Cards rather than paragraphs because the costs are the point: an `.srt`
/// is free and instant, burning re-encodes the whole video, and that ladder
/// is the product's actual shape. A wall of prose hides it.
struct CapabilityCard: Identifiable {
    struct Badge: Identifiable, Equatable {
        let text: String
        /// Free and immediate — worth marking, since most tools charge for it.
        let isFree: Bool
        var id: String { text }
    }

    let title: String
    let detail: String
    let badges: [Badge]
    let command: String
    let actionTitle: String

    var id: String { command }

    static let all: [CapabilityCard] = [
        CapabilityCard(
            title: "Subtitles for a video",
            detail: "Every line with its timecode, so you can fix a name I misheard "
                + "before anything is exported.",
            badges: [
                Badge(text: ".srt · instant", isFree: true),
                Badge(text: ".vtt · instant", isFree: true),
                Badge(text: "plain text · instant", isFree: true),
                Badge(text: "burn in · re-encodes", isFree: false)
            ],
            command: "/captions",
            actionTitle: "Choose a video"
        ),
        CapabilityCard(
            title: "Summaries of calls",
            detail: "What was decided and who agreed to what — every line linked back "
                + "to the second it was said.",
            badges: [
                Badge(text: "Reminders", isFree: false),
                Badge(text: "Calendar", isFree: false),
                Badge(text: ".ics · .csv", isFree: true),
                Badge(text: "Jira · Linear", isFree: false)
            ],
            command: "/summarize",
            actionTitle: "Record a call"
        )
    ]
}

/// A slash command: a way to start work without describing it in prose.
struct ChatCommand: Identifiable, Equatable {
    let name: String
    let summary: String

    var id: String { name }

    /// Kept in step with `COMMAND_SHEET` in `src/piko/commands/chat.py`, which
    /// is what lets the model suggest them without inventing syntax.
    static let all: [ChatCommand] = [
        ChatCommand(name: "/captions", summary: "Pick a video and get subtitles"),
        ChatCommand(name: "/summarize", summary: "Pick a recording and summarise the call"),
        ChatCommand(name: "/record", summary: "Start recording a call now"),
        ChatCommand(name: "/library", summary: "Browse past sessions"),
        ChatCommand(name: "/help", summary: "What Piko can do")
    ]

    static func matching(_ draft: String) -> [ChatCommand] {
        guard draft.hasPrefix("/") else { return [] }
        let typed = draft.lowercased()
        return all.filter { $0.name.hasPrefix(typed) }
    }
}
