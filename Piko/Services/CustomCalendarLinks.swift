import Foundation

/// A calendar service Piko does not know about, described by its own URL.
///
/// Google and Outlook are built in because their compose URLs are stable and
/// widely used — but Yandex, Fastmail, Zoho and every self-hosted thing have
/// their own, and hard-coding a list of them is a losing game. So the user
/// pastes the URL once, with placeholders where the event details go, and it
/// joins the same menu.
///
/// Values are filled in with the exact rules the built-in links use: the stated
/// time wins, then the original meeting's hour, then all-day.
struct CustomCalendarLink: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// A URL with `{title}`, `{start}`, `{end}`, `{details}`, `{location}`,
    /// `{guests}` anywhere in it.
    var template: String

    /// What a user can put in a template, with a word on each — shown in the
    /// editor, because a placeholder nobody can name is a placeholder nobody
    /// uses.
    static let placeholders: [(token: String, meaning: String)] = [
        ("{title}", "the action item's text"),
        ("{start}", "2026-08-09T15:00:00Z, or 2026-08-09 when all-day"),
        ("{end}", "same shape as {start}"),
        ("{start_basic}", "20260809T150000Z — the compact form some services want"),
        ("{end_basic}", "same shape as {start_basic}"),
        ("{details}", "the citation and the piko:// backlink"),
        ("{location}", "the call link, when there is one"),
        ("{guests}", "comma-separated addresses")
    ]

    func url(for item: ComposedItem,
             from recording: MeetingRecording,
             context: MeetingContext?) -> URL? {
        guard let day = DueDate.date(from: item.dueDate, time: item.dueTime) else { return nil }
        let slot = WebCalendarLink.slot(day, item: item, context: context)
        let values: [String: String] = [
            "{title}": item.text,
            "{start}": stamp(slot.start, day: slot.isAllDay, basic: false),
            "{end}": stamp(slot.end, day: slot.isAllDay, basic: false),
            "{start_basic}": stamp(slot.start, day: slot.isAllDay, basic: true),
            "{end_basic}": stamp(slot.end, day: slot.isAllDay, basic: true),
            "{details}": WebCalendarLink.details(for: item, from: recording, context: context),
            "{location}": context?.conferenceURL?.absoluteString ?? "",
            "{guests}": (context?.participants ?? []).compactMap(\.email).joined(separator: ",")
        ]

        var filled = template.trimmingCharacters(in: .whitespaces)
        for (token, value) in values {
            filled = filled.replacingOccurrences(of: token, with: encode(value))
        }
        return URL(string: filled)
    }

    /// Substituted values are escaped, the template around them is not — it is
    /// the user's own URL and may legitimately contain `?`, `&` and `/`.
    private func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func stamp(_ date: Date, day: Bool, basic: Bool) -> String {
        let pattern: String
        if day {
            pattern = basic ? "yyyyMMdd" : "yyyy-MM-dd"
        } else {
            pattern = basic ? "yyyyMMdd'T'HHmmss'Z'" : "yyyy-MM-dd'T'HH:mm:ss'Z'"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        if !day { formatter.timeZone = TimeZone(identifier: "UTC") }
        return formatter.string(from: date)
    }
}

enum CustomCalendarLinkStore {
    static let url: URL = MeetingLibrary.root
        .deletingLastPathComponent()
        .appendingPathComponent("calendar-links.json")

    static func load() -> [CustomCalendarLink] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CustomCalendarLink].self, from: data)) ?? []
    }

    @discardableResult
    static func save(_ links: [CustomCalendarLink]) -> [CustomCalendarLink] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if links.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? encoder.encode(links) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
        return links
    }

    static func add(name: String, template: String) -> [CustomCalendarLink] {
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let cleanTemplate = template.trimmingCharacters(in: .whitespaces)
        guard !cleanName.isEmpty, cleanTemplate.lowercased().hasPrefix("http") else { return load() }
        return save(load() + [CustomCalendarLink(name: cleanName, template: cleanTemplate)])
    }

    static func remove(_ link: CustomCalendarLink) -> [CustomCalendarLink] {
        save(load().filter { $0.id != link.id })
    }
}

/// Which built-in web calendars are worth showing on this Mac.
///
/// Google is useful to some people and noise to others; a company on
/// on-premise Exchange will never touch either Outlook entry. They ship
/// enabled — discovering a service you did have is better than missing one —
/// and hiding them is one click, remembered like any other preference.
enum WebCalendarVisibility {
    private static let key = "piko.hiddenWebCalendars"

    static var hidden: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static var visible: [WebCalendarLink.Service] {
        let hidden = hidden
        return WebCalendarLink.Service.allCases.filter { !hidden.contains($0.rawValue) }
    }

    static func setHidden(_ service: WebCalendarLink.Service, _ isHidden: Bool) {
        var hidden = hidden
        if isHidden { hidden.insert(service.rawValue) } else { hidden.remove(service.rawValue) }
        UserDefaults.standard.set(Array(hidden), forKey: key)
    }

    static func isVisible(_ service: WebCalendarLink.Service) -> Bool {
        !hidden.contains(service.rawValue)
    }
}
