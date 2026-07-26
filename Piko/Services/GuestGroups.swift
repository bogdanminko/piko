import Foundation

/// Named sets of people to invite, shared across every meeting.
///
/// Typing the same six addresses into every follow-up is the kind of work an
/// app is supposed to remove. Groups live beside the recordings rather than
/// inside one, because "the ML team" is not a property of a single call — it is
/// the same list next week.
///
/// Deliberately not a contacts integration: the Contacts grant would buy a name
/// resolver Piko does not need, and these addresses only ever leave the app
/// inside an .ics the user sends themselves.
struct GuestGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Email addresses, already validated as containing an "@".
    var emails: [String]

    var subtitle: String {
        emails.count == 1 ? emails[0] : "\(emails.count) people"
    }
}

enum GuestGroupStore {
    static let url: URL = MeetingLibrary.root
        .deletingLastPathComponent()
        .appendingPathComponent("guest-groups.json")

    static func load() -> [GuestGroup] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([GuestGroup].self, from: data)) ?? []
    }

    @discardableResult
    static func save(_ groups: [GuestGroup]) -> [GuestGroup] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if groups.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? encoder.encode(groups) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
        return groups
    }

    /// Adds or replaces by name — saving "ML team" twice updates it rather than
    /// leaving two chips that look identical.
    static func add(name: String, emails: [String]) -> [GuestGroup] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !emails.isEmpty else { return load() }
        var groups = load().filter { $0.name.caseInsensitiveCompare(trimmed) != .orderedSame }
        groups.append(GuestGroup(name: trimmed, emails: emails))
        return save(groups.sorted { $0.name.localizedCompare($1.name) == .orderedAscending })
    }

    /// Replaces by identity, so a group can be renamed without becoming a
    /// second chip beside the old one.
    static func update(_ group: GuestGroup) -> [GuestGroup] {
        guard !group.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !group.emails.isEmpty else { return remove(group) }
        var groups = load().filter { $0.id != group.id }
        groups.append(group)
        return save(groups.sorted { $0.name.localizedCompare($1.name) == .orderedAscending })
    }

    static func remove(_ group: GuestGroup) -> [GuestGroup] {
        save(load().filter { $0.id != group.id })
    }
}
