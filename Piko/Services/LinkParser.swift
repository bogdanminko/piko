import Foundation

/// Turns a real "create it" link — an event in a calendar, an issue in a tracker
/// — into a template.
///
/// Asking someone to hand-write `?title={title}&from={start}` is asking them to
/// do the app's job. Instead they paste a link the service actually produced —
/// its compose page, an issue, a board, whatever they had open — and this reads
/// the shape of it: a value that looks like a date is a date, a value with an "@"
/// is the guest list, a value under a parameter named `summary` is the title, and
/// for the services whose format is known the host and path alone are enough.
///
/// It is a guess, and it is shown before anything is saved: the reading appears
/// under the field so a wrong one is visible rather than silent.
enum LinkParser {
    /// What came of a pasted link.
    ///
    /// The two middle cases are what earn this being an enum rather than an
    /// optional. "Nothing to fill in here" is a true statement about a Jira board
    /// URL and a useless one: the service *was* recognised, it just cannot be
    /// prefilled from that particular address. Between a dead end and a full
    /// prefill there is room for a link that opens the right screen with the row
    /// on the clipboard, and for one that says exactly what it still needs.
    enum Reading {
        case ready(template: String, name: String)
        /// Recognised, and usable — but the service cannot be prefilled through a
        /// URL at all, so opening it will put the row on the clipboard instead.
        /// Strictly worse than `.ready` and strictly better than refusing: Jira
        /// without the project's numeric id is exactly this, and "you cannot use
        /// your own tracker" is not an acceptable answer to a pasted Jira link.
        case copyPaste(template: String, name: String, prefill: [String: String])
        /// `prefill` is whatever *was* readable — the address of the Jira, the
        /// GitLab host — keyed by the preset token it answers. A link that cannot
        /// be used whole still saves the user typing the part of it Piko understood.
        case incomplete(name: String, why: String, next: URL?, prefill: [String: String])
        case unrecognised

        var isUnrecognised: Bool {
            if case .unrecognised = self { return true }
            return false
        }

        /// The link this reading would save, or nil when there is nothing worth
        /// saving yet.
        var draft: Draft? {
            switch self {
            case .ready(let template, let name):
                return Draft(template: template, name: name, copiesText: false)
            case .copyPaste(let template, let name, _):
                return Draft(template: template, name: name, copiesText: true)
            case .incomplete, .unrecognised:
                return nil
            }
        }

        /// The answers this reading can hand to that preset's setup form, or
        /// nothing when it was about a different service.
        func prefill(for preset: LinkPreset) -> [String: String] {
            switch self {
            case .incomplete(let name, _, _, let prefill) where name == preset.name: return prefill
            case .copyPaste(_, let name, let prefill) where name == preset.name: return prefill
            default: return [:]
            }
        }
    }

    /// A link as it would be saved: what to open, what to call it, and whether
    /// opening it also has to hand the row over by clipboard.
    struct Draft {
        let template: String
        let name: String
        let copiesText: Bool
    }

    static func read(_ raw: String, kind: LinkKind) -> Reading {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme != nil else {
            return .unrecognised
        }

        switch kind {
        case .event:
            if let known = knownCalendar(components) {
                return .ready(template: known, name: suggestedName(from: trimmed, kind: kind))
            }
        case .task:
            let known = knownTracker(components)
            if !known.isUnrecognised { return known }
        }

        guard let generic = generic(components, kind: kind) else { return .unrecognised }
        return .ready(template: generic, name: suggestedName(from: trimmed, kind: kind))
    }

    // MARK: - Reading an unknown link by shape

    /// Parameter names worth trusting over the shape of their value, per kind.
    /// The two lists overlap on purpose — `summary` is Jira's title and iCal's
    /// too — and they diverge exactly where the kinds do: an event has two ends,
    /// a task has one deadline.
    private static let eventNames: [(placeholder: String, keys: Set<String>)] = [
        ("{title}", ["text", "title", "subject", "summary", "name", "event"]),
        ("{start}", ["start", "startdt", "from", "begin", "dtstart", "start_date", "starttime"]),
        ("{end}", ["end", "enddt", "to", "until", "dtend", "end_date", "endtime"]),
        ("{details}", ["details", "body", "description", "notes", "desc", "text2"]),
        ("{location}", ["location", "place", "where", "venue"]),
        ("{guests}", ["add", "attendees", "guests", "invitees", "email", "participants"])
    ]

    private static let taskNames: [(placeholder: String, keys: Set<String>)] = [
        ("{title}", ["title", "summary", "name", "content", "text", "task", "issue[title]"]),
        ("{details}", ["description", "body", "notes", "note", "desc", "details", "comment",
                       "issue[description]"]),
        ("{due_date}", ["duedate", "due", "due_date", "deadline", "date", "when"]),
        ("{owner}", ["assignee", "owner", "assigned_to", "responsible", "assignees"])
    ]

    private static func names(for kind: LinkKind) -> [(placeholder: String, keys: Set<String>)] {
        kind == .event ? eventNames : taskNames
    }

    private static let basicStamp = #/^\d{8}(T\d{6}Z?)?$/#
    private static let isoStamp = #/^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:?\d{2})?)?$/#

    /// Nil when there is nothing recognisable to replace — a bare calendar
    /// address carries no fields to fill in.
    private static func generic(_ components: URLComponents, kind: LinkKind) -> String? {
        var components = components
        guard let items = components.queryItems, !items.isEmpty else { return nil }

        var used: Set<String> = []
        var replaced = 0
        var rewritten: [URLQueryItem] = []

        for item in items {
            guard let value = item.value, !value.isEmpty else {
                rewritten.append(item)
                continue
            }
            if let placeholder = placeholder(for: item.name, value: value, used: used, kind: kind) {
                used.insert(placeholder)
                replaced += 1
                rewritten.append(URLQueryItem(name: item.name, value: placeholder))
            } else {
                rewritten.append(item)
            }
        }

        guard replaced > 0 else { return nil }
        components.queryItems = rewritten
        return components.url?.absoluteString.replacingOccurrences(of: "%7B", with: "{")
            .replacingOccurrences(of: "%7D", with: "}")
            .replacingOccurrences(of: "%2F", with: "/")
    }

    private static func placeholder(for name: String, value: String,
                                    used: Set<String>, kind: LinkKind) -> String? {
        let key = name.lowercased()

        if kind == .event, let stamp = eventStamp(key: key, value: value, used: used) {
            return stamp
        }
        // One deadline, and a tracker that spells it `date` still means the date.
        if kind == .task, isStamp(value), !used.contains("{due_date}") { return "{due_date}" }

        for (placeholder, _) in names(for: kind)
        where matches(key, placeholder, kind) && !used.contains(placeholder) {
            return placeholder
        }

        if kind == .event {
            if value.contains("@"), !used.contains("{guests}") { return "{guests}" }
            if value.lowercased().hasPrefix("http"), !used.contains("{location}") {
                return "{location}"
            }
        }
        return nil
    }

    private static func eventStamp(key: String, value: String, used: Set<String>) -> String? {
        // Google packs both ends into one parameter: "…T150000Z/…T153000Z".
        if value.contains("/") {
            let halves = value.split(separator: "/")
            if halves.count == 2, halves.allSatisfy(isStamp) {
                let basic = halves[0].contains("-") ? "" : "_basic"
                return "{start\(basic)}/{end\(basic)}"
            }
        }
        guard isStamp(value) else { return nil }
        let basic = value.contains("-") ? "" : "_basic"
        // A named parameter settles which end it is; otherwise the first
        // timestamp in the link is the start and the next one is the end.
        if matches(key, "{end}", .event)
            || (used.contains("{start\(basic)}") && !matches(key, "{start}", .event)) {
            return "{end\(basic)}"
        }
        return "{start\(basic)}"
    }

    private static func matches(_ key: String, _ placeholder: String, _ kind: LinkKind) -> Bool {
        names(for: kind).first { $0.placeholder == placeholder }?.keys.contains(key) ?? false
    }

    private static func isStamp(_ value: some StringProtocol) -> Bool {
        let text = String(value)
        return text.wholeMatch(of: basicStamp) != nil || text.wholeMatch(of: isoStamp) != nil
    }

    /// "calendar.yandex.ru" → "Yandex Calendar", "acme.atlassian.net" → "Jira"
    /// where the shape is obvious, the host itself otherwise. Only a suggestion;
    /// the field stays editable.
    static func suggestedName(from raw: String, kind: LinkKind) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let components = URLComponents(string: trimmed) else { return "" }
        let host = components.host?.lowercased() ?? ""

        if let scheme = components.scheme?.lowercased(),
           let preset = LinkPreset.all.first(where: { $0.scheme == scheme }) {
            return preset.name
        }
        if let preset = LinkPreset.all.first(where: { preset in
            guard let domain = preset.domain else { return false }
            return host.hasSuffix(domain)
        }) {
            return preset.name
        }
        if kind == .task { return host }

        if components.path.lowercased().contains("/owa") {
            return "Outlook (\(host))"
        }
        // Skip the "calendar"/"www" prefix and the TLD to find the brand.
        let parts = host.split(separator: ".").map(String.init)
        let brand = parts.first { !["www", "calendar", "cal", "app", "my", "mail"].contains($0) }
            ?? host
        return brand.prefix(1).uppercased() + brand.dropFirst() + " Calendar"
    }
}
