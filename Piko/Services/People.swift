import Foundation

/// Who a task belongs to, and what that person is called in the systems it gets
/// sent to.
///
/// An item's `owner` is a name somebody said out loud — "Аня", "Dima", "Sarah
/// from ops". No tracker can resolve one of those to an account, which is why
/// Piko refused for a long time to put it in an assignee field: a name written
/// where an id is expected produces an issue assigned to nobody.
///
/// This is the missing half — the translation table, maintained by the person
/// who knows the answers. The spoken name stays the evidence; the handle beside
/// it is what actually reaches Jira or GitHub. Deliberately not a Contacts
/// integration and not a directory lookup: both would cost a grant or a token to
/// answer a question the user can answer in five seconds, and neither knows the
/// accountId on the self-hosted Jira down the hall anyway.
struct Person: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What gets said in a meeting. Matched loosely — see `matches`.
    var name: String
    var email: String?
    /// Other spellings of the same person: "Аня" for "Anna", a surname on its
    /// own. A summary quotes whatever was spoken, and that is rarely one form.
    var aliases: [String] = []
    /// Service slug (`LinkPreset.service`) → the id that service wants. Jira
    /// Cloud wants an accountId, GitHub a login. One field per service because
    /// they genuinely differ; there is no universal handle to store instead.
    var handles: [String: String] = [:]

    /// The id to write into `service`'s assignee field.
    ///
    /// Never the name, and never the address as a substitute for a missing id:
    /// Jira Cloud resolves an accountId and GitHub a login, so an email in
    /// either field is a parameter that is ignored at best and rejected at
    /// worst. The address is only offered where the service is unknown — a
    /// hand-pasted link to something Piko has no preset for, where an address is
    /// the likeliest thing an `assignee=` parameter would accept.
    func handle(for service: String?) -> String? {
        guard let service else { return email?.nonEmpty }
        return handles[service]?.nonEmpty
    }

    /// The trackers this person can actually be assigned in, by name.
    var assignableIn: [String] {
        LinkPreset.assigneeServices
            .filter { handles[$0.service]?.nonEmpty != nil }
            .map(\.name)
    }

    /// What a CSV importer can match on. Jira, Asana and Linear all resolve a
    /// person by address on import, and none of them takes an accountId there.
    var importValue: String? { email?.nonEmpty }

    /// Every spelling this person answers to, normalized.
    var keys: [String] {
        ([name] + aliases + [email ?? ""]).map(PeopleBook.normalize).filter { !$0.isEmpty }
    }

    func matches(_ spoken: String) -> Bool {
        keys.contains(PeopleBook.normalize(spoken))
    }

    var subtitle: String {
        let services = handles.filter { !$0.value.isEmpty }.keys.sorted()
        return ([email].compactMap { $0?.nonEmpty } + services).joined(separator: " · ")
    }
}

/// The people file, app-level: "Dima is @dmitry on GitHub" is not a property of
/// one call, and re-answering it per meeting would be the same work every time.
enum PeopleBook {
    static let url: URL = MeetingLibrary.root
        .deletingLastPathComponent()
        .appendingPathComponent("people.json")

    static func load() -> [Person] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Person].self, from: data)) ?? []
    }

    @discardableResult
    static func save(_ people: [Person]) -> [Person] {
        let sorted = people.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if sorted.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? encoder.encode(sorted) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
        return sorted
    }

    /// Replaces by identity, so renaming somebody does not leave two entries
    /// that look like two people.
    @discardableResult
    static func update(_ person: Person) -> [Person] {
        guard !person.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return remove(person)
        }
        return save(load().filter { $0.id != person.id } + [person])
    }

    static func remove(_ person: Person) -> [Person] {
        save(load().filter { $0.id != person.id })
    }

    /// The person an item's owner refers to, if the book knows them.
    static func find(_ spoken: String?, in people: [Person]? = nil) -> Person? {
        guard let spoken = spoken?.nonEmpty else { return nil }
        return (people ?? load()).first { $0.matches(spoken) }
    }

    /// What `{assignee}` resolves to for this link — empty when the book has
    /// nothing, which drops the parameter rather than sending a name.
    static func handle(for spoken: String?, service: String?) -> String? {
        find(spoken)?.handle(for: service)
    }

    /// Case, spacing and the Cyrillic/Latin lookalikes people mix without
    /// noticing. Crude on purpose: it only has to tell "Anna" from "Dima".
    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "  ", with: " ")
    }
}

extension String {
    /// The string itself, or nil when it is blank — an empty field and a missing
    /// one mean the same thing everywhere in this feature.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
