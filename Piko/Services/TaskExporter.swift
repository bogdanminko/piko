import EventKit
import Foundation

/// Action items → Apple Reminders or Calendar, through EventKit.
///
/// EventKit and not a cloud API on purpose: no key, no OAuth, no account, and
/// not a single network request — one system Allow, and the write lands in
/// whatever accounts the Mac already has, *including Google and Exchange*. A
/// Notion or Todoist integration would need a token and would send the meeting
/// off the machine, which is the one thing Piko promises not to do.
///
/// What makes this more than a text dump is the URL on every item —
/// `piko://meeting/<id>?t=612.4` reopens Piko at the second it was agreed on,
/// so a task can still prove where it came from after it has left the app.
@MainActor
final class TaskExporter {
    /// Where an item can be sent *without leaving Piko for another app's UI*.
    /// Most action items are tasks; the ones that *are* a meeting ("let's sync in
    /// two weeks") belong in the calendar instead — that is the first distinction
    /// this enum carries. The second is a file versus a store: a file reaches
    /// every calendar and every tracker and costs no permission, EventKit only
    /// reaches accounts this Mac is signed into but can be updated later.
    /// Order is the order they are offered in: the two event paths, then the two
    /// task ones. Everything else a row can be sent to is a link — see
    /// LinkTemplate — because it is the other app's own screen that opens.
    enum Target: String, CaseIterable, Identifiable {
        /// An .ics document — the format every calendar reads, and the only one
        /// that can carry a guest list. See CalendarFile.
        case icsFile = "ics"
        case calendar
        case reminders
        /// A CSV every tracker imports, and the only path that moves the whole
        /// list at once. See TaskFile.
        case csvFile = "csv"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .icsFile: return "ICS"
            case .calendar: return "Calendar"
            case .reminders: return "Reminders"
            case .csvFile: return "CSV"
            }
        }

        var badge: String {
            switch self {
            case .reminders: return "In Reminders"
            case .calendar: return "In Calendar"
            case .icsFile: return "Saved .ics"
            case .csvFile: return "Saved .csv"
            }
        }

        var icon: String {
            switch self {
            case .reminders: return "checklist"
            case .calendar: return "calendar"
            case .icsFile: return "doc"
            case .csvFile: return "tablecells"
            }
        }

        /// What the review sheet says about this destination. It lives with the
        /// destination rather than with the sheet: the trade-offs described
        /// here are properties of the path, not of the screen.
        var explanation: String {
            switch self {
            case .icsFile:
                return "An .ics file every calendar reads — Google, Outlook, Fantastical. It "
                    + "opens after saving, and it is the only path that can carry the guest "
                    + "list, because sending the invitation stays your call."
            case .calendar:
                return "For the items that are themselves a meeting. Each one lands on its "
                    + "resolved day — all-day unless a time was stated — with the same link back."
            case .reminders:
                return "Tasks land in the “Piko” list. Each one carries the cited line and a "
                    + "piko:// link back to the second it was agreed on."
            case .csvFile:
                return "A CSV to import into Jira, Linear, Asana, Trello or Monday — the whole list "
                    + "in one go, with no account and no token. Nothing comes back, so import it "
                    + "once: a second import makes duplicates."
            }
        }

        /// An event needs a day to sit on; a task does not.
        var requiresDate: Bool { self == .icsFile || self == .calendar }

        /// Writing a file needs nothing from the system.
        var needsPermission: Bool { self == .calendar || self == .reminders }

        /// Deep link into the exact Privacy pane. A denial is otherwise a dead
        /// end: the user is told where to go and left to find it.
        var settingsURL: URL? {
            switch self {
            case .icsFile, .csvFile: return nil
            case .calendar, .reminders:
                let pane = self == .calendar ? "Privacy_Calendars" : "Privacy_Reminders"
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
            }
        }
    }

    /// Where the last send went, so the next one opens there.
    ///
    /// People pick a lane and stay in it: somebody who exports a `.csv` of their
    /// action items is not about to put the same rows in a calendar, and landing
    /// on ICS every single time makes the sheet re-ask a question that was
    /// answered for good. App-level rather than per-meeting — it is a property of
    /// how this person works, not of one call.
    enum LastUsed {
        private static let key = "piko.lastExportTarget"

        static var target: Target {
            get {
                Target(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .icsFile
            }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
        }
    }

    /// The list Piko creates on first use. Reminders is the user's own space —
    /// tasks go into one clearly-labelled list rather than their inbox.
    /// Events go to the default calendar instead: a separate "Piko" calendar
    /// would be off by default in most people's week view.
    nonisolated static let listName = "Piko"
    /// Follow-ups nobody gave a time for become all-day entries; the ones with
    /// a stated time get this much room.
    nonisolated static let eventMinutes: Double = 30

    enum ExportError: LocalizedError {
        case denied(Target)
        case noStore(Target)
        case needsDate
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied(let target):
                return "Piko has no access to \(target.title). Turn it on in System Settings → "
                    + "Privacy & Security → \(target.title)."
            case .noStore(let target):
                return "No \(target.title) account is set up on this Mac."
            case .needsDate:
                return "A calendar entry needs a date, and none of the selected items has one."
            case .failed(let detail):
                return "Could not write it: \(detail)"
            }
        }
    }

    private let store = EKEventStore()

    /// Raises the system prompt on first call; afterwards it just reports.
    func requestAccess(_ target: Target) async throws {
        let granted = switch target {
        case .reminders: try await store.requestFullAccessToReminders()
        case .calendar: try await store.requestFullAccessToEvents()
        case .icsFile, .csvFile: true
        }
        if !granted { throw ExportError.denied(target) }
    }

    /// Writes each item and returns its EventKit identifier, keyed by the row's
    /// id. A row that went to this target before is updated in place — hence
    /// the identifier being kept in the overlay.
    func send(_ items: [ComposedItem],
              from recording: MeetingRecording,
              to target: Target,
              context: MeetingContext? = nil) async throws -> [String: String] {
        try await requestAccess(target)
        switch target {
        case .reminders: return try sendReminders(items, from: recording)
        case .calendar: return try sendEvents(items, from: recording, context: context)
        // Written by CalendarFile / TaskFile — no store is involved in either.
        case .icsFile, .csvFile: return [:]
        }
    }

    /// The meeting this recording came from, if the calendar knows it. Read
    /// only — used to give a follow-up the same room, hour and people.
    func context(for recording: MeetingRecording) -> MeetingContext? {
        MeetingContext.find(for: recording, in: store)
    }

    // MARK: - Reminders

    private func sendReminders(_ items: [ComposedItem],
                               from recording: MeetingRecording) throws -> [String: String] {
        let list = try remindersList()
        var identifiers: [String: String] = [:]

        for item in items {
            // An update keeps whichever list the user may have moved it to.
            let reminder = existingReminder(item) ?? EKReminder(eventStore: store)
            if reminder.calendar == nil { reminder.calendar = list }
            reminder.title = item.text
            reminder.notes = notes(for: item, from: recording)
            reminder.url = PikoURL.make(recordingID: recording.id, at: item.start)
            reminder.isCompleted = item.isDone
            reminder.dueDateComponents = dueComponents(item)

            do {
                try store.save(reminder, commit: false)
                identifiers[item.id] = reminder.calendarItemIdentifier
            } catch {
                throw ExportError.failed(error.localizedDescription)
            }
        }

        try commit()
        return identifiers
    }

    private func existingReminder(_ item: ComposedItem) -> EKReminder? {
        guard let record = item.export(to: Target.reminders.rawValue) else { return nil }
        return store.calendarItem(withIdentifier: record.externalID) as? EKReminder
    }

    private func remindersList() throws -> EKCalendar {
        let lists = store.calendars(for: .reminder)
        if let existing = lists.first(where: { $0.title == Self.listName }) {
            return existing
        }
        guard let source = store.defaultCalendarForNewReminders()?.source ?? lists.first?.source else {
            throw ExportError.noStore(.reminders)
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = Self.listName
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            // A source that refuses new lists (some managed accounts) should
            // not block the export — fall back to where reminders normally go.
            if let fallback = store.defaultCalendarForNewReminders() { return fallback }
            throw ExportError.failed(error.localizedDescription)
        }
    }

    // MARK: - Calendar

    /// Items without a resolved date are skipped rather than parked on today:
    /// an event on a guessed day is worse than no event.
    private func sendEvents(_ items: [ComposedItem],
                            from recording: MeetingRecording,
                            context: MeetingContext?) throws -> [String: String] {
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw ExportError.noStore(.calendar)
        }
        var identifiers: [String: String] = [:]
        var wrote = false

        for item in items {
            guard let day = DueDate.date(from: item.dueDate, time: item.dueTime) else { continue }
            let event = existingEvent(item) ?? EKEvent(eventStore: store)
            if event.calendar == nil { event.calendar = calendar }
            event.title = item.text
            event.notes = notes(for: item, from: recording, context: context)
            event.url = PikoURL.make(recordingID: recording.id, at: item.start)
            // The link goes in the location because that is the field calendars
            // turn into a Join button.
            event.location = context?.conferenceURL?.absoluteString
            schedule(event, on: day, statedTime: item.dueTime != nil, context: context)

            do {
                try store.save(event, span: .thisEvent, commit: false)
                identifiers[item.id] = event.eventIdentifier
                wrote = true
            } catch {
                throw ExportError.failed(error.localizedDescription)
            }
        }

        guard wrote else { throw ExportError.needsDate }
        try commit()
        return identifiers
    }

    /// When the follow-up sits on the day.
    ///
    /// A stated time wins. Failing that, the original meeting's hour and length
    /// are the best available answer — a follow-up to a 15:00 standup belongs
    /// at 15:00. With neither, it stays all-day: nobody said an hour, and
    /// inventing one is the same failure as inventing a timecode.
    private func schedule(_ event: EKEvent, on day: Date,
                          statedTime: Bool, context: MeetingContext?) {
        if statedTime {
            event.isAllDay = false
            event.startDate = day
            event.endDate = day.addingTimeInterval(Self.eventMinutes * 60)
        } else if let context, let start = context.startDate(on: day) {
            event.isAllDay = false
            event.startDate = start
            event.endDate = start.addingTimeInterval(context.durationMinutes * 60)
        } else {
            event.isAllDay = true
            event.startDate = day
            event.endDate = day
        }
    }

    private func existingEvent(_ item: ComposedItem) -> EKEvent? {
        guard let record = item.export(to: Target.calendar.rawValue) else { return nil }
        return store.event(withIdentifier: record.externalID)
    }

    // MARK: - Shared

    private func commit() throws {
        do {
            try store.commit()
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
    }

    /// The citation travels with the task: what was said, when, and in which
    /// meeting. An entry read three weeks later is otherwise contextless.
    private func notes(for item: ComposedItem,
                       from recording: MeetingRecording,
                       context: MeetingContext? = nil) -> String {
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
        if let context {
            lines.append("")
            lines.append("Follow-up to “\(context.title)”")
            // Listed, not invited: EventKit keeps attendees read-only, so this
            // is a reminder of who to add — Piko cannot invite for you.
            if !context.participants.isEmpty {
                let names = context.participants.map(\.display).joined(separator: ", ")
                lines.append("Were on the call: \(names)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func dueComponents(_ item: ComposedItem) -> DateComponents? {
        guard let date = DueDate.date(from: item.dueDate, time: item.dueTime) else { return nil }
        var units: Set<Calendar.Component> = [.year, .month, .day]
        if item.dueTime != nil {
            units.formUnion([.hour, .minute])
        }
        return Calendar.current.dateComponents(units, from: date)
    }
}

/// Links back into the app: `piko://meeting/<recording-id>?t=612.4`.
///
/// This is what keeps an exported task verifiable — PRODUCT.md's promise does
/// not stop at the window edge. Parsing stays deliberately narrow: a recording
/// id and a number of seconds, never a path.
enum PikoURL {
    static let scheme = "piko"

    static func make(recordingID: String, at seconds: Double?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "meeting"
        components.path = "/\(recordingID)"
        if let seconds {
            components.queryItems = [URLQueryItem(name: "t", value: String(format: "%.1f", seconds))]
        }
        return components.url
    }

    /// Display form for the review sheet, where the full URL would be noise.
    static func shortLabel(at seconds: Double?) -> String {
        guard let seconds else { return "piko://…" }
        return String(format: "piko://…?t=%.1f", seconds)
    }

    static func parse(_ url: URL) -> (recordingID: String, seconds: Double?)? {
        guard url.scheme == scheme, url.host == "meeting" else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Recording ids are timestamps ("2026-07-26-201416"); anything with a
        // separator in it is not one of ours.
        guard !id.isEmpty, !id.contains("/"), !id.contains("..") else { return nil }
        let seconds = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "t" }?.value
        return (id, seconds.flatMap(Double.init))
    }
}
