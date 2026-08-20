import EventKit
import Foundation

/// The calendar event a recording came from, when one can be identified.
///
/// A follow-up agreed on a call ("let's sync in two weeks") should land in the
/// same room with the same people — but Piko cannot invent either: a
/// conferencing link needs an account, and EventKit makes `EKEvent.attendees`
/// read-only on purpose, so no app can invite on your behalf. What it *can* do
/// is read the meeting that produced the recording and carry its link, its time
/// of day and its participant list over. Nothing here is generated; it is
/// copied from an event the user already has.
struct MeetingContext: Equatable {
    let title: String
    /// Time of day and length the original meeting had — a follow-up to a 15:00
    /// standup belongs at 15:00, not on an all-day banner.
    let start: Date
    let durationMinutes: Double
    /// Meet/Zoom/Teams link found on the source event, if it had one.
    let conferenceURL: URL?
    let participants: [Participant]
    /// Who sent the original invite, when the event names them. Used as the
    /// ORGANIZER of an .ics follow-up, which is what makes it a real invite.
    let organizer: Participant?

    /// Someone who was on the call. The address is only ever reused to build
    /// an invitation the user sends themselves.
    struct Participant: Equatable {
        let name: String?
        let email: String?

        var display: String { name ?? email ?? "Unknown" }
    }
    /// Share of the recording the event covers, 0…1. Kept so the UI can say
    /// *why* this event was picked rather than asserting it.
    let overlap: Double

    /// How far outside the recording an event may sit and still be the same
    /// meeting — people start recording late and stop early.
    static let searchPadding: TimeInterval = 30 * 60
    /// Below this share of the recording it is a different meeting that merely
    /// overlapped ("Lunch" inside a two-hour call).
    static let minimumOverlap: Double = 0.5
    /// A clip this short cannot be matched meaningfully against an hour-long
    /// event; the overlap ratio would be flattering and meaningless.
    static let minimumRecording: TimeInterval = 120

    /// Hosts whose links are a way to join a call rather than a page about one.
    static let conferenceHosts = [
        "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "around.co", "gather.town",
        "telemost.yandex.ru", "ktalk.ru", "salutejazz.ru", "vats.mts.ru"
    ]

    /// The event that best covers this recording, or nil.
    ///
    /// Deliberately conservative — a wrong meeting attached to a follow-up is
    /// worse than no meeting, because the user would be sent to the wrong room.
    @MainActor
    static func find(for recording: MeetingRecording, in store: EKEventStore) -> MeetingContext? {
        // An imported file's `started_at` is when it was imported, not when the
        // call happened, so matching it by time would compare against the wrong
        // hour entirely.
        guard !recording.isImported,
              recording.duration >= minimumRecording,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }

        let start = recording.startedAt
        let end = start.addingTimeInterval(recording.duration)
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-searchPadding),
            end: end.addingTimeInterval(searchPadding),
            calendars: nil
        )

        let best = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .map { (event: $0, overlap: overlap($0, from: start, to: end)) }
            .filter { $0.overlap >= minimumOverlap }
            .max { left, right in left.overlap < right.overlap }

        guard let best, let eventStart = best.event.startDate else { return nil }
        let eventEnd = best.event.endDate ?? eventStart.addingTimeInterval(30 * 60)

        return MeetingContext(
            title: best.event.title ?? "Untitled meeting",
            start: eventStart,
            durationMinutes: max(15, eventEnd.timeIntervalSince(eventStart) / 60),
            conferenceURL: conferenceLink(in: best.event),
            participants: people(in: best.event),
            organizer: best.event.organizer.map(participant),
            overlap: best.overlap
        )
    }

    /// Share of the *recording* the event covers. Measured against the
    /// recording rather than the event so a long calendar block does not
    /// swallow a short clip.
    private static func overlap(_ event: EKEvent, from start: Date, to end: Date) -> Double {
        guard let eventStart = event.startDate, let eventEnd = event.endDate else { return 0 }
        let shared = min(end, eventEnd).timeIntervalSince(max(start, eventStart))
        let length = end.timeIntervalSince(start)
        return length > 0 ? max(0, shared) / length : 0
    }

    /// Conferencing links live wherever the calendar that made them put them —
    /// the URL field for Google, the location for some clients, the notes for
    /// the rest. All three get scanned, first match wins.
    private static func conferenceLink(in event: EKEvent) -> URL? {
        var haystack: [String] = []
        if let url = event.url?.absoluteString { haystack.append(url) }
        if let location = event.location { haystack.append(location) }
        if let notes = event.notes { haystack.append(notes) }

        for text in haystack {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(text.startIndex..., in: text)
            let matches = detector?.matches(in: text, range: range) ?? []
            for match in matches {
                guard let url = match.url, let host = url.host?.lowercased() else { continue }
                if conferenceHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                    return url
                }
            }
        }
        return nil
    }

    /// Who was invited, the user themselves left out.
    private static func people(in event: EKEvent) -> [Participant] {
        (event.attendees ?? [])
            .filter { !$0.isCurrentUser }
            .map(participant)
            .filter { $0.name != nil || $0.email != nil }
    }

    /// EventKit gives an address as a `mailto:` URL; an .ics needs the address.
    private static func participant(_ attendee: EKParticipant) -> Participant {
        let name = attendee.name?.trimmingCharacters(in: .whitespaces)
        let raw = attendee.url.absoluteString
        let email = raw.hasPrefix("mailto:") ? String(raw.dropFirst("mailto:".count)) : nil
        return Participant(name: (name?.isEmpty ?? true) ? nil : name,
                           email: (email?.isEmpty ?? true) ? nil : email)
    }

    /// The follow-up's start: the day the deadline resolved to, at the hour the
    /// original meeting was held.
    func startDate(on day: Date) -> Date? {
        let calendar = Calendar.current
        let clock = calendar.dateComponents([.hour, .minute], from: start)
        return calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0,
                             second: 0, of: day)
    }

    /// One line for the sheet: what was matched and how well.
    /// A context standing on typed-in details rather than a matched event —
    /// the recording's own time and length, plus whatever the user supplied.
    static func manual(for recording: MeetingRecording,
                       followUp: SummaryEdits.FollowUp) -> MeetingContext? {
        guard !followUp.isEmpty else { return nil }
        return MeetingContext(
            title: recording.title,
            start: recording.startedAt,
            durationMinutes: max(15, recording.duration / 60),
            conferenceURL: followUp.conferenceURL.flatMap { URL(string: $0) },
            participants: followUp.guests.map { Participant(name: nil, email: $0) },
            organizer: followUp.organizer.map { Participant(name: nil, email: $0) },
            overlap: 0
        )
    }

    /// This context with typed-in details layered over it: a link or guest list
    /// the user entered wins over whatever the matched event carried.
    func overridden(by followUp: SummaryEdits.FollowUp) -> MeetingContext {
        MeetingContext(
            title: title,
            start: start,
            durationMinutes: durationMinutes,
            conferenceURL: followUp.conferenceURL.flatMap { URL(string: $0) } ?? conferenceURL,
            participants: followUp.guests.isEmpty
                ? participants
                : followUp.guests.map { Participant(name: nil, email: $0) },
            organizer: followUp.organizer.map { Participant(name: nil, email: $0) } ?? organizer,
            overlap: overlap
        )
    }

    var summaryLine: String {
        var parts = ["Continues “\(title)”"]
        if conferenceURL != nil { parts.append("same call link") }
        if !participants.isEmpty { parts.append("\(participants.count) participants") }
        return parts.joined(separator: " · ")
    }
}
