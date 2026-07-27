import AppKit
import Foundation

/// Action items as a CSV file — the tracker counterpart to `CalendarFile`.
///
/// Jira, Linear, Asana, Trello, ClickUp and Monday all import CSV, and not one
/// of them needs an account on this Mac, a token, or a network request from Piko
/// to do it. That makes this both the cheapest path that reaches a tracker at
/// all and the only one that moves a whole list in one go: every other route is
/// one compose screen per row.
///
/// The trade-off is the same as the `.ics`: a file is a snapshot, nothing comes
/// back, so a second export writes a second file rather than updating anything.
/// Unlike an `.ics` there is not even a UID convention to lean on — importers
/// mint their own ids — so re-importing the same file makes duplicates. Send the
/// list once, then use a link or Reminders for the strays.
enum TaskFile {
    /// Jira's spelling, because Jira is the least forgiving of the importers and
    /// the others let you map columns by hand anyway. `Epic Link` is Jira's own
    /// column name for it, and Linear and ClickUp both map it onto their parent
    /// on import.
    static let columns = ["Summary", "Description", "Due Date", "Assignee", "Epic Link",
                          "Status", "URL"]

    /// Nil when there is nothing to write. Rows without a resolved deadline are
    /// kept, unlike in the calendar paths: a task with no date is still a task.
    static func make(_ items: [ComposedItem], from recording: MeetingRecording) -> String? {
        guard !items.isEmpty else { return nil }
        let people = PeopleBook.load()
        var rows = [columns.map(field).joined(separator: ",")]
        rows += items.map { item in
            [
                item.text,
                ItemNote.make(for: item, from: recording),
                due(item),
                assignee(item, people: people),
                item.epic ?? "",
                item.isDone ? "Done" : "To Do",
                PikoURL.make(recordingID: recording.id, at: item.start)?.absoluteString ?? ""
            ]
            .map(field)
            .joined(separator: ",")
        }
        // RFC 4180 line endings: the importers that care want CRLF, the rest
        // do not mind.
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// The address where People knows one, the spoken name otherwise.
    ///
    /// An importer resolves a person by username or email and never by an
    /// accountId — that is the URL path's currency, not a file's — so this asks
    /// for `importValue` rather than the tracker handle. The name is still
    /// written when nothing is known: a column somebody maps by hand beats an
    /// empty one, and unlike a URL parameter it cannot be silently misread.
    private static func assignee(_ item: ComposedItem, people: [Person]) -> String {
        PeopleBook.find(item.owner, in: people)?.importValue ?? item.owner ?? ""
    }

    /// ISO, with the hour only when somebody stated one. Every importer asks
    /// which date format the file uses, and this is the one they all offer.
    private static func due(_ item: ComposedItem) -> String {
        guard let day = item.dueDate, !day.isEmpty else { return "" }
        guard let time = item.dueTime, !time.isEmpty else { return day }
        return "\(day) \(time)"
    }

    /// The characters that mean something to a CSV reader. A `Set` rather than a
    /// string to search: `"\r\n"` inside a Swift string is one grapheme cluster,
    /// so looking for a bare newline in it finds nothing — and the citation is
    /// multi-line by design, which is exactly the field that must be quoted.
    private static let structural: Set<Character> = [",", "\"", ";", "\r", "\n"]

    /// A field is quoted whenever it contains structure, and a quote inside one
    /// is doubled.
    private static func field(_ value: String) -> String {
        guard value.contains(where: structural.contains) else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Save panel → file → reveal it. Deliberately not opened: a double-click on
    /// a CSV launches Numbers, and the file's whole purpose is to be handed to a
    /// tracker's import screen instead.
    @MainActor
    static func save(_ document: String, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + ".csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            // No BOM: Jira's importer reads it as part of the first column name.
            try document.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return url
    }
}
