import Foundation

/// The string a destination is recorded under in the overlay — see
/// `SummaryEdits.ExportRecord.target`.
///
/// EventKit and the file paths keep the bare names they have always been stored
/// under, so an overlay written before any of this existed still shows its
/// badges. Web calendars and saved links are prefixed and carry their own
/// identity: there can be any number of them, and one row can legitimately have
/// gone to several.
///
/// What those two can claim is narrower than what EventKit can. No identifier
/// comes back from a compose screen, and whether the user pressed Create over
/// there is not ours to know — so their badge says "opened", and sending again
/// opens the screen again rather than updating anything.
enum ExportKey {
    static func web(_ service: WebCalendarLink.Service) -> String { "web:\(service.rawValue)" }

    static func link(_ template: LinkTemplate) -> String { "link:\(template.id.uuidString)" }

    /// A built-in tracker has no saved record to point at, so it is recorded under
    /// the preset's own identity — the same string that hides it from the menu.
    static func preset(_ preset: LinkPreset) -> String { preset.visibilityID }

    static func badge(_ target: String, links: [LinkTemplate]) -> String {
        if let known = TaskExporter.Target(rawValue: target) { return known.badge }
        if let service = service(target) { return "Opened in \(service.shortTitle)" }
        if let preset = preset(named: target) { return "Opened in \(preset.name)" }
        if let link = link(target, in: links) { return "Opened in \(link.name)" }
        // A link the user has since deleted. The send still happened.
        return "Opened"
    }

    static func icon(_ target: String) -> String {
        TaskExporter.Target(rawValue: target)?.icon ?? "arrow.up.forward"
    }

    private static func preset(named target: String) -> LinkPreset? {
        LinkPreset.all.first { $0.visibilityID == target }
    }

    private static func service(_ target: String) -> WebCalendarLink.Service? {
        guard target.hasPrefix("web:") else { return nil }
        return WebCalendarLink.Service(rawValue: String(target.dropFirst(4)))
    }

    private static func link(_ target: String, in links: [LinkTemplate]) -> LinkTemplate? {
        guard target.hasPrefix("link:") else { return nil }
        let id = String(target.dropFirst(5))
        return links.first { $0.id.uuidString == id }
    }
}
