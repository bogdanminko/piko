import AppKit
import Foundation

/// What a link makes on the other side: an entry in a calendar, or a row in a
/// tracker.
///
/// The two are one type with a kind rather than two near-identical ones, and
/// that is the whole reason Jira and Google Calendar share a parser, a store, a
/// menu and a sheet. They differ in exactly the two ways that matter: an event
/// has to sit on a day and can carry a guest list, a task needs neither.
enum LinkKind: String, Codable, CaseIterable, Identifiable {
    case event
    case task

    var id: String { rawValue }

    /// What the submenu holding links of this kind is called.
    var menuTitle: String {
        switch self {
        case .event: return "Open in web calendar"
        case .task: return "Open in task tracker"
        }
    }

    var addTitle: String {
        switch self {
        case .event: return "Add calendar link…"
        case .task: return "Add task link…"
        }
    }

    var sheetTitle: String {
        switch self {
        case .event: return "Calendar links"
        case .task: return "Task links"
        }
    }

    /// The sheet's opening sentence — what this kind of link is and is not.
    var blurb: String {
        switch self {
        case .event:
            return "Paste a link your calendar produced for creating an event — Piko reads it and "
                + "works out which part is the title, the date and the guests. No account, no "
                + "access to the calendar itself."
        case .task:
            return "The ones listed work as they are. Jira, GitHub, GitLab and Linear need to know "
                + "which project first — set one up below, or just paste any link from it and Piko "
                + "reads the project out of the address. Either way its own screen opens with the "
                + "row filled in, for you to press Create. No token, no API."
        }
    }
}

/// A destination Piko does not know about, described by its own URL.
///
/// Google and Outlook are built in because their compose URLs are stable and
/// widely used — but Yandex, Fastmail, Zoho, Jira, Linear and every self-hosted
/// thing have their own, and hard-coding a list of them is a losing game. So the
/// URL is stated once, with placeholders where the details go, and it joins the
/// same menu.
///
/// Values are filled in with the exact rules the built-in links use: for an
/// event the stated time wins, then the original meeting's hour, then all-day.
struct LinkTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: LinkKind = .event
    /// A URL with any of `placeholders(for:)`'s tokens anywhere in it.
    var template: String
    /// For a service that cannot be prefilled through a URL at all: open its
    /// create screen and put the row on the clipboard, so it is one ⌘V away
    /// rather than out of reach. Jira without the project's numeric id is the
    /// case this exists for.
    var copiesText: Bool = false

    init(name: String, kind: LinkKind, template: String, copiesText: Bool = false) {
        self.name = name
        self.kind = kind
        self.template = template
        self.copiesText = copiesText
    }

    /// Entries written before there was more than one kind have no `kind` field.
    /// They are calendar links: that is all this file used to hold.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(LinkKind.self, forKey: .kind) ?? .event
        template = try container.decode(String.self, forKey: .template)
        copiesText = try container.decodeIfPresent(Bool.self, forKey: .copiesText) ?? false
    }

    /// What a user can put in a template, with a word on each — shown in the
    /// editor, because a placeholder nobody can name is a placeholder nobody
    /// uses.
    static func placeholders(for kind: LinkKind) -> [(token: String, meaning: String)] {
        switch kind {
        case .event: return eventPlaceholders
        case .task: return taskPlaceholders
        }
    }

    private static let eventPlaceholders: [(token: String, meaning: String)] = [
        ("{title}", "the action item's text"),
        ("{start}", "2026-08-09T15:00:00Z, or 2026-08-09 when all-day"),
        ("{end}", "same shape as {start}"),
        ("{start_basic}", "20260809T150000Z — the compact form some services want"),
        ("{end_basic}", "same shape as {start_basic}"),
        ("{details}", "the citation and the piko:// backlink"),
        ("{location}", "the call link, when there is one"),
        ("{guests}", "comma-separated addresses"),
        ("{link}", "the piko:// backlink on its own")
    ]

    private static let taskPlaceholders: [(token: String, meaning: String)] = [
        ("{title}", "the action item's text"),
        ("{details}", "the citation, the owner, the epic and the piko:// backlink"),
        ("{due_date}", "2026-08-09 — empty when nothing resolved"),
        ("{due}", "the deadline as it was spoken"),
        ("{owner}", "the name that was said, as text"),
        ("{assignee}", "that person's id in this tracker, from People — empty when unknown"),
        ("{epic}", "the epic key for the row, or the meeting's"),
        ("{meeting}", "the recording's title"),
        ("{link}", "the piko:// backlink on its own")
    ]

    /// Which tracker this link points at, so `{assignee}` knows which id to
    /// reach for: the same person is an accountId in Jira and a login on GitHub.
    ///
    /// Read off the URL rather than stored, so a link that was pasted in and one
    /// built from a preset answer the same way — and so links saved before any
    /// of this existed pick it up without a migration.
    var service: String? { LinkPreset.service(forTemplate: template) }

    func url(for item: ComposedItem,
             from recording: MeetingRecording,
             context: MeetingContext?) -> URL? {
        guard let values = values(for: item, from: recording, context: context) else { return nil }

        var filled = template.trimmingCharacters(in: .whitespaces)
        // An empty value takes its query parameter with it. `date=` reads as a
        // date to some services and as a malformed request to others, and
        // neither is what "nobody said when" means.
        for (token, value) in values where value.isEmpty {
            filled = LinkTemplate.dropParameter(containing: token, from: filled)
        }
        for (token, value) in values {
            filled = filled.replacingOccurrences(of: token, with: encode(value))
        }
        return URL(string: filled)
    }

    /// Nil when this kind cannot describe the row at all — an event with no
    /// resolved day. A task is fine without one.
    private func values(for item: ComposedItem,
                        from recording: MeetingRecording,
                        context: MeetingContext?) -> [String: String]? {
        let backlink = PikoURL.make(recordingID: recording.id, at: item.start)?.absoluteString ?? ""
        switch kind {
        case .task:
            return [
                "{title}": item.text,
                "{details}": ItemNote.make(for: item, from: recording),
                "{due_date}": item.dueDate ?? "",
                "{due}": item.due ?? "",
                "{owner}": item.owner ?? "",
                // Empty when nobody has told Piko who that name is over there,
                // which drops the parameter — an unresolvable assignee is worse
                // than none, since the tracker would silently ignore it anyway.
                "{assignee}": PeopleBook.handle(for: item.owner, service: service) ?? "",
                "{epic}": item.epic ?? "",
                "{meeting}": recording.title,
                "{link}": backlink
            ]
        case .event:
            guard let day = DueDate.date(from: item.dueDate, time: item.dueTime) else { return nil }
            let slot = WebCalendarLink.slot(day, item: item, context: context)
            return [
                "{title}": item.text,
                "{start}": stamp(slot.start, day: slot.isAllDay, basic: false),
                "{end}": stamp(slot.end, day: slot.isAllDay, basic: false),
                "{start_basic}": stamp(slot.start, day: slot.isAllDay, basic: true),
                "{end_basic}": stamp(slot.end, day: slot.isAllDay, basic: true),
                "{details}": WebCalendarLink.details(for: item, from: recording, context: context),
                "{location}": context?.conferenceURL?.absoluteString ?? "",
                "{guests}": (context?.participants ?? []).compactMap(\.email).joined(separator: ","),
                "{link}": backlink
            ]
        }
    }

    /// Removes the `&name={token}` pair the token sits in. The first component
    /// carries the path and the `?`, so it is never dropped: a template that put
    /// an optional value there would otherwise lose the URL itself.
    static func dropParameter(containing token: String, from text: String) -> String {
        let parts = text.split(separator: "&", omittingEmptySubsequences: false).map(String.init)
        return parts.filter { !$0.contains(token) || $0.contains("?") }.joined(separator: "&")
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

enum LinkTemplateStore {
    static let url: URL = MeetingLibrary.root
        .deletingLastPathComponent()
        .appendingPathComponent("links.json")

    /// Where calendar links lived when calendars were the only kind. Read once,
    /// rewritten into `links.json`, then removed.
    private static let legacyURL: URL = MeetingLibrary.root
        .deletingLastPathComponent()
        .appendingPathComponent("calendar-links.json")

    static func load() -> [LinkTemplate] {
        if let data = try? Data(contentsOf: url) {
            return (try? JSONDecoder().decode([LinkTemplate].self, from: data)) ?? []
        }
        guard let legacy = try? Data(contentsOf: legacyURL),
              let links = try? JSONDecoder().decode([LinkTemplate].self, from: legacy) else {
            return []
        }
        save(links)
        try? FileManager.default.removeItem(at: legacyURL)
        return links
    }

    static func load(_ kind: LinkKind) -> [LinkTemplate] {
        load().filter { $0.kind == kind }
    }

    @discardableResult
    static func save(_ links: [LinkTemplate]) -> [LinkTemplate] {
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

    static func add(name: String, kind: LinkKind, template: String,
                    copiesText: Bool = false) -> [LinkTemplate] {
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let cleanTemplate = template.trimmingCharacters(in: .whitespaces)
        guard !cleanName.isEmpty, isOpenable(cleanTemplate) else { return load() }
        return save(load() + [LinkTemplate(name: cleanName, kind: kind,
                                           template: cleanTemplate, copiesText: copiesText)])
    }

    static func remove(_ link: LinkTemplate) -> [LinkTemplate] {
        save(load().filter { $0.id != link.id })
    }

    /// Something the system can open. Web links are the common case, but Things,
    /// OmniFocus and Todoist are reached by their own scheme — the app is on the
    /// Mac, and asking it directly beats asking its website.
    static func isOpenable(_ template: String) -> Bool {
        guard let scheme = URLComponents(string: template.trimmingCharacters(in: .whitespaces))?.scheme
        else { return false }
        return !scheme.isEmpty
    }
}

/// Which of the destinations that need no setup are worth showing on this Mac.
///
/// Google Calendar is useful to some people and noise to others; a company on
/// on-premise Exchange will never touch either Outlook entry; somebody who has
/// never opened Trello does not want it in a menu. They all ship enabled —
/// discovering a service you did have is better than missing one — and hiding one
/// is a click, remembered like any other preference.
enum BuiltInLinkVisibility {
    /// The key predates task links. Renaming it would silently unhide whatever
    /// somebody had already hidden, which is not worth a tidier string.
    private static let key = "piko.hiddenWebCalendars"

    static var hidden: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func isVisible(_ id: String) -> Bool { !hidden.contains(id) }

    static func setHidden(_ id: String, _ isHidden: Bool) {
        var hidden = hidden
        if isHidden { hidden.insert(id) } else { hidden.remove(id) }
        UserDefaults.standard.set(Array(hidden), forKey: key)
    }

    static var calendars: [WebCalendarLink.Service] {
        WebCalendarLink.Service.allCases.filter { isVisible($0.rawValue) }
    }

    /// The zero-setup trackers, minus the ones this Mac cannot open. A menu entry
    /// for Things on a Mac without Things is a promise the machine cannot keep —
    /// and unlike a web link, there is nothing to fall back to.
    @MainActor
    static var trackers: [LinkPreset] {
        LinkPreset.builtIn.filter { preset in
            guard isVisible(preset.visibilityID) else { return false }
            return isInstalled(preset)
        }
    }

    @MainActor
    static func isInstalled(_ preset: LinkPreset) -> Bool {
        guard preset.needsApp else { return true }
        // The template still has its placeholders in it, which is fine: only the
        // scheme decides who answers.
        guard let url = URL(string: preset.template) else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }
}
