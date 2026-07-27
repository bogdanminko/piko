import Foundation

/// The citation that travels with a row once it leaves Piko: which meeting,
/// which second, what was actually said about the deadline, and a `piko://`
/// link back to it.
///
/// A task read three weeks later in a tracker is otherwise contextless — and
/// the backlink is what keeps PRODUCT.md's verifiability promise alive past the
/// window edge.
///
/// The owner is written here as the name that was said, always. It *also*
/// reaches the tracker's own assignee field, but only through `{assignee}` and
/// only when People holds an id for that person (see People.swift) — a name in
/// a field expecting an account produces an issue assigned to nobody, so the
/// two are separate values and this is the one that never fails.
///
/// The epic is the same story one field along: it goes in its own custom field
/// where the link was set up to carry one, and lands here regardless, because
/// "which epic" is worth reading even when it could not be set.
enum ItemNote {
    /// The whole row as text to paste by hand, for a service whose create screen
    /// takes no URL parameters. The title comes first because that is the field
    /// the cursor lands in; the citation follows, so the backlink survives a path
    /// that cannot carry it in a URL.
    static func pasteable(for item: ComposedItem, from recording: MeetingRecording) -> String {
        item.text + "\n\n" + make(for: item, from: recording)
    }

    static func make(for item: ComposedItem, from recording: MeetingRecording) -> String {
        var lines = ["From “\(recording.title)”"]
        if let start = item.start {
            lines.append("At \(MeetingSummaryCards.clockText(start)) in the recording")
        }
        if let due = item.due, !due.isEmpty {
            lines.append("Said as: “\(due)”")
        }
        if let owner = item.owner, !owner.isEmpty {
            lines.append("Owner: \(owner)")
        }
        if let epic = item.epic, !epic.isEmpty {
            lines.append("Epic: \(epic)")
        }
        if let backlink = PikoURL.make(recordingID: recording.id, at: item.start) {
            lines.append(backlink.absoluteString)
        }
        return lines.joined(separator: "\n")
    }
}
