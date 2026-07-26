import Foundation

/// Turns a real "create event" link into a template.
///
/// Asking someone to hand-write `?title={title}&from={start}` is asking them to
/// do the app's job. Instead they paste a link their calendar actually
/// produced — from its compose page, or from a "add to calendar" button
/// somewhere — and this reads the shape of it: a value that looks like a date
/// is a date, a value with an "@" is the guest list, the longest piece of prose
/// is the title. Each recognised value is swapped for its placeholder.
///
/// It is a guess, and it is shown before anything is saved: the parsed template
/// appears under the field so a wrong reading is visible rather than silent.
enum CalendarLinkParser {
    /// Parameter names worth trusting over the shape of their value.
    private static let names: [(placeholder: String, keys: Set<String>)] = [
        ("{title}", ["text", "title", "subject", "summary", "name", "event"]),
        ("{start}", ["start", "startdt", "from", "begin", "dtstart", "start_date", "starttime"]),
        ("{end}", ["end", "enddt", "to", "until", "dtend", "end_date", "endtime"]),
        ("{details}", ["details", "body", "description", "notes", "desc", "text2"]),
        ("{location}", ["location", "place", "where", "venue"]),
        ("{guests}", ["add", "attendees", "guests", "invitees", "email", "participants"])
    ]

    private static let basicStamp = #/^\d{8}(T\d{6}Z?)?$/#
    private static let isoStamp = #/^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:?\d{2})?)?$/#

    /// Services whose compose format is known, recognised from any of their
    /// URLs. This is what makes a corporate Exchange usable: nobody can get a
    /// "create event" link out of on-premise OWA, but its compose parameters
    /// are the standard ones, so knowing the host is enough.
    private static func known(_ components: URLComponents) -> String? {
        let host = components.host?.lowercased() ?? ""
        let path = components.path.lowercased()
        let fields = "subject={title}&startdt={start}&enddt={end}&body={details}"
            + "&location={location}&to={guests}"

        // On-premise OWA: https://mail.company.com/owa/…
        if path.hasPrefix("/owa") || path.contains("/owa/") {
            return "https://\(host)/owa/?path=/calendar/action/compose&rru=addevent&\(fields)"
        }
        if host.hasSuffix("outlook.office.com") || host.hasSuffix("outlook.office365.com")
            || host.hasSuffix("outlook.live.com") {
            return "https://\(host)/calendar/0/deeplink/compose"
                + "?path=/calendar/action/compose&rru=addevent&\(fields)"
        }
        if host.hasSuffix("calendar.google.com") {
            return "https://calendar.google.com/calendar/render?action=TEMPLATE"
                + "&text={title}&dates={start_basic}/{end_basic}"
                + "&details={details}&location={location}&add={guests}"
        }
        return nil
    }

    /// The template, or nil when there is nothing recognisable to replace —
    /// a bare calendar address carries no fields to fill in.
    static func template(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), let known = known(components) {
            return known
        }
        guard var components = URLComponents(string: trimmed),
              let items = components.queryItems, !items.isEmpty else { return nil }

        var used: Set<String> = []
        var replaced = 0
        var rewritten: [URLQueryItem] = []

        for item in items {
            guard let value = item.value, !value.isEmpty else {
                rewritten.append(item)
                continue
            }
            if let placeholder = placeholder(for: item.name, value: value, used: used) {
                used.insert(placeholder)
                replaced += 1
                rewritten.append(URLQueryItem(name: item.name, value: placeholder))
            } else {
                rewritten.append(item)
            }
        }

        guard replaced > 0 else { return nil }
        // A title alone is not worth a menu entry; a date makes it an event.
        components.queryItems = rewritten
        return components.url?.absoluteString.replacingOccurrences(of: "%7B", with: "{")
            .replacingOccurrences(of: "%7D", with: "}")
            .replacingOccurrences(of: "%2F", with: "/")
    }

    private static func placeholder(for name: String, value: String, used: Set<String>) -> String? {
        let key = name.lowercased()

        // Google packs both ends into one parameter: "…T150000Z/…T153000Z".
        if value.contains("/") {
            let halves = value.split(separator: "/")
            if halves.count == 2, halves.allSatisfy(isStamp) {
                let basic = halves[0].contains("-") ? "" : "_basic"
                return "{start\(basic)}/{end\(basic)}"
            }
        }

        if isStamp(value) {
            let basic = value.contains("-") ? "" : "_basic"
            // A named parameter settles which end it is; otherwise the first
            // timestamp in the link is the start and the next one is the end.
            if matches(key, "{end}") || (used.contains("{start\(basic)}") && !matches(key, "{start}")) {
                return "{end\(basic)}"
            }
            return "{start\(basic)}"
        }

        for (placeholder, _) in names where matches(key, placeholder) && !used.contains(placeholder) {
            return placeholder
        }

        if value.contains("@"), !used.contains("{guests}") { return "{guests}" }
        if value.lowercased().hasPrefix("http"), !used.contains("{location}") { return "{location}" }
        return nil
    }

    private static func matches(_ key: String, _ placeholder: String) -> Bool {
        names.first { $0.placeholder == placeholder }?.keys.contains(key) ?? false
    }

    private static func isStamp(_ value: some StringProtocol) -> Bool {
        let text = String(value)
        return text.wholeMatch(of: basicStamp) != nil || text.wholeMatch(of: isoStamp) != nil
    }

    /// "calendar.yandex.ru" → "Yandex Calendar" where the shape is obvious,
    /// the host itself otherwise. Only a suggestion; the field stays editable.
    static func suggestedName(from raw: String) -> String {
        guard let host = URLComponents(string: raw.trimmingCharacters(in: .whitespaces))?.host else {
            return ""
        }
        let parts = host.split(separator: ".").map(String.init)
        // Skip the "calendar"/"www" prefix and the TLD to find the brand.
        if URLComponents(string: raw)?.path.lowercased().contains("/owa") == true {
            return "Outlook (\(host))"
        }
        let brand = parts.first { !["www", "calendar", "cal", "app", "my", "mail"].contains($0) }
            ?? host
        return brand.prefix(1).uppercased() + brand.dropFirst() + " Calendar"
    }
}
