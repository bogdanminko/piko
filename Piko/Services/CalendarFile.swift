import AppKit
import Foundation

/// Follow-ups as an `.ics` file (iCalendar, RFC 5545) — the format every
/// calendar reads.
///
/// This is the answer to "nobody keeps their meetings in Apple Calendar".
/// EventKit only reaches accounts the Mac itself is signed into; someone whose
/// work calendar lives in a browser tab is invisible to it. An .ics needs no
/// account, no permission and no entitlement — Google Calendar, Outlook,
/// Fantastical and Notion Calendar all import it.
///
/// It also gets past the one wall EventKit puts up: `EKEvent.attendees` is
/// read-only, but an .ics carries `ATTENDEE` lines, which is literally what an
/// invitation email is made of. Piko still does not send anything — the user
/// opens the file and their own calendar does the inviting.
///
/// The trade-off is deliberate: a file is a snapshot. Nothing comes back, so a
/// second export writes a second file rather than updating the first. When
/// updates matter, EventKit is the path.
enum CalendarFile {
    /// Turns the picked rows into one calendar document.
    /// Rows without a resolved date are skipped — an event needs a day.
    static func make(_ items: [ComposedItem],
                     from recording: MeetingRecording,
                     context: MeetingContext?) -> String? {
        let events = items.compactMap { event(for: $0, from: recording, context: context) }
        guard !events.isEmpty else { return nil }

        // REQUEST is the invitation method, and it is only well-formed with an
        // organizer to send it. Without both, this is a published event, and
        // claiming otherwise makes some clients reject the file outright.
        let hasGuests = !(context?.participants.isEmpty ?? true)
            && context?.organizer?.email != nil
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Piko//Meeting Summary//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:\(hasGuests ? "REQUEST" : "PUBLISH")"
        ]
        lines += events.flatMap { $0 }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    private static func event(for item: ComposedItem,
                              from recording: MeetingRecording,
                              context: MeetingContext?) -> [String]? {
        guard let day = DueDate.date(from: item.dueDate, time: item.dueTime) else { return nil }

        var lines = ["BEGIN:VEVENT"]
        // Stable per row and per meeting, so re-importing the same file updates
        // the event a calendar already has instead of duplicating it.
        lines.append("UID:\(uid(for: item, in: recording))")
        lines.append("DTSTAMP:\(utc(Date()))")
        lines += schedule(day: day, statedTime: item.dueTime != nil, context: context)
        lines.append("SUMMARY:\(escape(item.text))")
        lines.append("DESCRIPTION:\(escape(description(for: item, from: recording, context: context)))")

        if let link = context?.conferenceURL {
            lines.append("LOCATION:\(escape(link.absoluteString))")
            lines.append("X-GOOGLE-CONFERENCE:\(escape(link.absoluteString))")
        }
        if let backlink = PikoURL.make(recordingID: recording.id, at: item.start) {
            lines.append("URL:\(escape(backlink.absoluteString))")
        }
        if let organizer = context?.organizer, let email = organizer.email {
            lines.append("ORGANIZER\(commonName(organizer.name)):mailto:\(email)")
        }
        for guest in context?.participants ?? [] {
            guard let email = guest.email else { continue }
            let name = commonName(guest.name)
            lines.append("ATTENDEE\(name);ROLE=REQ-PARTICIPANT;RSVP=TRUE:mailto:\(email)")
        }
        lines.append("END:VEVENT")
        return lines
    }

    /// Same rule as the EventKit path: a stated time wins, the source meeting's
    /// hour is the next best answer, and with neither it stays all-day rather
    /// than inventing an hour.
    private static func schedule(day: Date, statedTime: Bool,
                                 context: MeetingContext?) -> [String] {
        if statedTime {
            return ["DTSTART:\(utc(day))",
                    "DTEND:\(utc(day.addingTimeInterval(TaskExporter.eventMinutes * 60)))"]
        }
        if let context, let start = context.startDate(on: day) {
            return ["DTSTART:\(utc(start))",
                    "DTEND:\(utc(start.addingTimeInterval(context.durationMinutes * 60)))"]
        }
        // DTEND of an all-day event is exclusive — the next day.
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        return ["DTSTART;VALUE=DATE:\(dayStamp(day))", "DTEND;VALUE=DATE:\(dayStamp(next))"]
    }

    private static func description(for item: ComposedItem,
                                    from recording: MeetingRecording,
                                    context: MeetingContext?) -> String {
        var lines = ["From “\(recording.title)”"]
        if let start = item.start {
            lines.append("At \(MeetingSummaryCards.clockText(start)) in the recording")
        }
        if let due = item.due, !due.isEmpty {
            lines.append("Said as: “\(due)”")
        }
        if let context {
            lines.append("Follow-up to “\(context.title)”")
        }
        if let backlink = PikoURL.make(recordingID: recording.id, at: item.start) {
            lines.append(backlink.absoluteString)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Writing it out

    /// Save panel → file → hand it to the default calendar app, which is where
    /// the user accepts it and sends the invitations. Returns the path written,
    /// or nil if they cancelled.
    @MainActor
    static func save(_ document: String, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + ".ics"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try document.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        NSWorkspace.shared.open(url)
        return url
    }

    /// The corporate path: the invitation travels by mail, the way it does in
    /// every company that has ever existed. No compose URL, no calendar API —
    /// the .ics goes out as an attachment through whatever mail client the Mac
    /// is set up with, and the recipients' calendars turn it into an invite.
    @MainActor
    static func email(_ document: String, to guests: [String], subject: String) -> Bool {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName(subject) + ".ics")
        do {
            try document.data(using: .utf8)?.write(to: file, options: .atomic)
        } catch {
            return false
        }

        guard let service = NSSharingService(named: .composeEmail) else { return false }
        service.recipients = guests
        service.subject = subject
        let body = "Sent from Piko — the attached invitation carries the agreed time and "
            + "a link back to the moment it was agreed on."
        let items: [Any] = [body, file]
        guard service.canPerform(withItems: items) else { return false }
        service.perform(withItems: items)
        return true
    }

    private static func safeName(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "invite" : String(cleaned.prefix(60))
    }

    // MARK: - Encoding

    private static func uid(for item: ComposedItem, in recording: MeetingRecording) -> String {
        let seed = "\(recording.id)-\(item.id)"
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .joined()
        return "\(seed)@piko.local"
    }

    private static func utc(_ date: Date) -> String {
        stamp(date, format: "yyyyMMdd'T'HHmmss'Z'", utc: true)
    }

    private static func dayStamp(_ date: Date) -> String {
        stamp(date, format: "yyyyMMdd", utc: false)
    }

    private static func stamp(_ date: Date, format: String, utc: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if utc { formatter.timeZone = TimeZone(identifier: "UTC") }
        return formatter.string(from: date)
    }

    /// A parameter value is quoted rather than escaped, and the two characters
    /// that cannot appear inside quotes are dropped.
    private static func commonName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        let clean = name.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
        return ";CN=\"\(clean)\""
    }

    /// RFC 5545 escaping: backslash, semicolon, comma and newline are structure.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Lines are limited to 75 octets; continuations start with a space.
    /// Folding counts bytes, not characters — a Cyrillic summary is two bytes
    /// per letter, and splitting one in half would corrupt the file.
    private static func fold(_ line: String) -> String {
        let bytes = Array(line.utf8)
        guard bytes.count > 75 else { return line }

        var pieces: [String] = []
        var current: [UInt8] = []
        var limit = 75
        for byte in bytes {
            // Never break between the bytes of one character.
            let isContinuation = byte & 0xC0 == 0x80
            if current.count >= limit, !isContinuation {
                pieces.append(String(bytes: current, encoding: .utf8) ?? "")
                current = []
                limit = 74
            }
            current.append(byte)
        }
        if !current.isEmpty { pieces.append(String(bytes: current, encoding: .utf8) ?? "") }
        return pieces.joined(separator: "\r\n ")
    }
}

/// Keyless "add to calendar" links for the people who live in a browser tab.
/// No account, no API — the calendar's own compose screen opens prefilled, and
/// guests are added there, in the UI that is allowed to invite them.
enum WebCalendarLink {
    /// The web calendars that accept a prefilled compose screen. Which host to
    /// use is not something Piko can know — a work Microsoft account and a
    /// personal one live on different domains — so both are offered.
    enum Service: String, CaseIterable, Identifiable {
        case google
        case outlookWork
        case outlookPersonal

        var id: String { rawValue }

        var title: String {
            switch self {
            case .google: return "Google Calendar"
            case .outlookWork: return "Outlook (work)"
            case .outlookPersonal: return "Outlook (personal)"
            }
        }

        /// For the badge on a row, where the full name does not fit and the
        /// work/personal split is not what the reader is asking about.
        var shortTitle: String {
            switch self {
            case .google: return "Google"
            case .outlookWork, .outlookPersonal: return "Outlook"
            }
        }
    }

    static func url(_ service: Service,
                    for item: ComposedItem,
                    from recording: MeetingRecording,
                    context: MeetingContext?) -> URL? {
        guard let day = DueDate.date(from: item.dueDate, time: item.dueTime) else { return nil }
        let slot = slot(day, item: item, context: context)
        let guests = (context?.participants ?? []).compactMap(\.email)
        let details = details(for: item, from: recording, context: context)

        switch service {
        case .google:
            return google(item, slot: slot, details: details, guests: guests, context: context)
        case .outlookWork:
            return outlook(host: "outlook.office.com", item: item, slot: slot, details: details,
                           invitees: Invitees(guests: guests, context: context))
        case .outlookPersonal:
            return outlook(host: "outlook.live.com", item: item, slot: slot, details: details,
                           invitees: Invitees(guests: guests, context: context))
        }
    }

    /// Who is being invited and what the follow-up inherits — one bag, because
    /// the two always travel together into a link.
    private struct Invitees {
        let guests: [String]
        let context: MeetingContext?
    }

    /// Start, end, and whether the day is the whole claim.
    struct Slot {
        let start: Date
        let end: Date
        let isAllDay: Bool
    }

    static func slot(_ day: Date, item: ComposedItem, context: MeetingContext?) -> Slot {
        if item.dueTime != nil {
            return Slot(start: day,
                        end: day.addingTimeInterval(TaskExporter.eventMinutes * 60),
                        isAllDay: false)
        }
        if let context, let start = context.startDate(on: day) {
            return Slot(start: start,
                        end: start.addingTimeInterval(context.durationMinutes * 60),
                        isAllDay: false)
        }
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        return Slot(start: day, end: next, isAllDay: true)
    }

    static func details(for item: ComposedItem,
                        from recording: MeetingRecording,
                        context: MeetingContext?) -> String {
        var lines = ["From “\(recording.title)”"]
        if let backlink = PikoURL.make(recordingID: recording.id, at: item.start) {
            lines.append(backlink.absoluteString)
        }
        if let people = context?.participants, !people.isEmpty {
            lines.append("Were on the call: " + people.map(\.display).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private static func google(_ item: ComposedItem, slot: Slot, details: String,
                               guests: [String], context: MeetingContext?) -> URL? {
        var components = URLComponents(string: "https://calendar.google.com/calendar/render")
        let dates = slot.isAllDay
            ? "\(stamp(slot.start, day: true))/\(stamp(slot.end, day: true))"
            : "\(stamp(slot.start, day: false))/\(stamp(slot.end, day: false))"
        var query = [
            URLQueryItem(name: "action", value: "TEMPLATE"),
            URLQueryItem(name: "text", value: item.text),
            URLQueryItem(name: "dates", value: dates),
            URLQueryItem(name: "details", value: details)
        ]
        if let link = context?.conferenceURL {
            query.append(URLQueryItem(name: "location", value: link.absoluteString))
        }
        // Google prefills guests from `add`, then lets the user send the invite.
        if !guests.isEmpty {
            query.append(URLQueryItem(name: "add", value: guests.joined(separator: ",")))
        }
        components?.queryItems = query
        return components?.url
    }

    /// Outlook on the web takes the same idea with different spelling: ISO
    /// timestamps, `to` for the guest list, and an explicit all-day flag.
    private static func outlook(host: String, item: ComposedItem, slot: Slot,
                                details: String, invitees: Invitees) -> URL? {
        let guests = invitees.guests
        let context = invitees.context
        var components = URLComponents(string: "https://\(host)/calendar/0/deeplink/compose")
        var query = [
            URLQueryItem(name: "path", value: "/calendar/action/compose"),
            URLQueryItem(name: "rru", value: "addevent"),
            URLQueryItem(name: "subject", value: item.text),
            URLQueryItem(name: "startdt", value: iso(slot.start, day: slot.isAllDay)),
            URLQueryItem(name: "enddt", value: iso(slot.end, day: slot.isAllDay)),
            URLQueryItem(name: "body", value: details)
        ]
        if slot.isAllDay {
            query.append(URLQueryItem(name: "allday", value: "true"))
        }
        if let link = context?.conferenceURL {
            query.append(URLQueryItem(name: "location", value: link.absoluteString))
        }
        if !guests.isEmpty {
            query.append(URLQueryItem(name: "to", value: guests.joined(separator: ",")))
        }
        components?.queryItems = query
        return components?.url
    }

    private static func stamp(_ date: Date, day: Bool) -> String {
        format(date, pattern: day ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'", utc: !day)
    }

    private static func iso(_ date: Date, day: Bool) -> String {
        format(date, pattern: day ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm:ss'Z'", utc: !day)
    }

    private static func format(_ date: Date, pattern: String, utc: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        if utc { formatter.timeZone = TimeZone(identifier: "UTC") }
        return formatter.string(from: date)
    }
}
