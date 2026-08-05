import AppKit
import Foundation

/// A summary as a Markdown document the user can keep anywhere.
///
/// Deliberately a snapshot, not a sync: Piko stays the source of truth, and the
/// file it hands out carries `piko://` links so any line can be traced back to
/// the recording. That is also why there is no Apple Notes integration — Notes
/// has no public API, and a share sheet plus a linked snapshot does the same
/// job without an AppleScript bridge that breaks.
enum MarkdownExport {
    /// `notes` are the lines the user typed during the call. They are their own
    /// section rather than being folded into the summary: the model was told to
    /// use them, but what a person wrote is worth reading as they wrote it.
    static func make(_ summary: ComposedSummary, for recording: MeetingRecording,
                     notes: [MeetingNote] = []) -> String {
        var lines: [String] = ["# \(recording.title)", ""]

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var meta = [formatter.string(from: recording.startedAt)]
        if recording.duration > 0 {
            meta.append(MeetingSummaryCards.clockText(recording.duration))
        }
        lines += [meta.joined(separator: " · "), ""]

        if !summary.brief.isEmpty {
            lines += [summary.brief, ""]
        }
        if !summary.topics.isEmpty {
            lines += ["**Topics:** " + summary.topics.joined(separator: " · "), ""]
        }
        if !summary.summary.isEmpty {
            lines += ["## Summary", "", summary.summary, ""]
        }

        if !summary.decisions.isEmpty {
            lines += ["## Decisions", ""]
            lines += summary.decisions.map { "- \($0.text)\(link($0, recording))" }
            lines.append("")
        }

        if !summary.actionItems.isEmpty {
            lines += ["## Action items", ""]
            lines += summary.actionItems.map { task($0, recording) }
            lines.append("")
        }

        if !summary.openQuestions.isEmpty {
            lines += ["## Open questions", ""]
            lines += summary.openQuestions.map { "- \($0.text)\(link($0, recording))" }
            lines.append("")
        }

        if !notes.isEmpty {
            lines += ["## Notes", ""]
            lines += notes.map { note in
                "- \(note.text)" + noteLink(note, recording)
            }
            lines.append("")
        }

        lines += ["---", "Summarized locally by Piko. Timecodes link back into the recording."]
        return lines.joined(separator: "\n")
    }

    // MARK: - Pieces
    //
    // The same renderers the whole document is built from, so copying one card
    // gives text that reads like the export rather than a second format that
    // drifts from it.

    static func brief(_ summary: ComposedSummary) -> String {
        var lines = [summary.brief]
        if !summary.topics.isEmpty {
            lines += ["", "**Topics:** " + summary.topics.joined(separator: " · ")]
        }
        if !summary.summary.isEmpty {
            lines += ["", summary.summary]
        }
        return lines.joined(separator: "\n")
    }

    /// One card as a Markdown list. Action items keep their checkbox, owner and
    /// deadline; the other two lists are plain bullets.
    static func section(_ title: String, items: [ComposedItem],
                        for recording: MeetingRecording, checkboxes: Bool = false) -> String {
        var lines = ["## \(title)", ""]
        lines += items.map { item in
            checkboxes ? task(item, recording) : "- \(item.text)" + link(item, recording)
        }
        return lines.joined(separator: "\n")
    }

    /// One action item: the box, the text, who owns it, when it is due and
    /// which epic it belongs under — the same line in the document and on the
    /// clipboard, so copying one card cannot drift from exporting the file.
    private static func task(_ item: ComposedItem, _ recording: MeetingRecording) -> String {
        var line = "- [\(item.isDone ? "x" : " ")] \(item.text)"
        if let owner = item.owner?.nonEmpty { line += " — \(owner)" }
        if let due = DueDate.label(item.dueDate, time: item.dueTime) {
            line += " — due \(due)"
        } else if let spoken = item.due?.nonEmpty {
            line += " — due “\(spoken)”"
        }
        if let epic = item.epic?.nonEmpty { line += " — \(epic)" }
        return line + link(item, recording)
    }

    /// The transcript as it reads on screen: who said it, when, and what.
    static func transcript(_ transcript: MeetingTranscript) -> String {
        transcript.segments.map { segment in
            let speaker = transcript.speakers[segment.speaker] ?? segment.speaker
            return "[\(MeetingSummaryCards.clockText(segment.start))] \(speaker): \(segment.text)"
        }
        .joined(separator: "\n")
    }

    /// `[12:40](piko://meeting/<id>?t=760.0)` — the citation, clickable in any
    /// Markdown reader on this Mac.
    private static func link(_ item: ComposedItem, _ recording: MeetingRecording) -> String {
        guard let start = item.start,
              let url = PikoURL.make(recordingID: recording.id, at: start) else { return "" }
        return " [\(MeetingSummaryCards.clockText(start))](\(url.absoluteString))"
    }

    /// A note keeps its own citation where it has one; an untimed note is just
    /// text, and a link to second zero would be a citation to nothing.
    private static func noteLink(_ note: MeetingNote, _ recording: MeetingRecording) -> String {
        guard let at = note.at, let url = PikoURL.make(recordingID: recording.id, at: at) else {
            return ""
        }
        return " [\(MeetingSummaryCards.clockText(at))](\(url.absoluteString))"
    }

    /// Save panel → file. Returns false when the user cancelled.
    @MainActor
    @discardableResult
    static func save(_ text: String, suggestedName: String) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + ".md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        return true
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
