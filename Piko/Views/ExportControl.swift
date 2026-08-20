import SwiftUI

/// Where a row can be sent, as a menu.
///
/// The same list appears in two places — the row's right-click menu and the
/// badge that says where it already went — so it lives in one view rather than
/// being written twice and drifting.
///
/// Grouped by what the row *is*, not by the mechanism, because that is the only
/// choice the reader actually makes: a follow-up is an event, "collect the eval
/// set" is a task. Nobody who just saved a `.csv` of their action items is about
/// to put the same rows in a calendar, so the two sets are separated instead of
/// being one flat list of six. Within a group the order is what the path costs:
/// a file needs nothing, EventKit needs one Allow, a link needs the other app's
/// screen.
struct ExportDestinations: View {
    let item: ComposedItem
    /// Saved links of both kinds. Split here rather than by every caller, so the
    /// menu and the badge read from one list.
    let links: [LinkTemplate]
    /// Built-in web calendars the user has not hidden.
    let services: [WebCalendarLink.Service]
    /// Built-in trackers: nothing to set up, and this Mac can open them.
    let trackers: [LinkPreset]
    let onSend: ([ComposedItem], TaskExporter.Target) -> Void
    let onOpenWeb: (ComposedItem, WebCalendarLink.Service) -> Void
    let onOpenPreset: (ComposedItem, LinkPreset) -> Void
    let onOpenLink: (ComposedItem, LinkTemplate) -> Void
    let onManageLinks: (LinkKind) -> Void

    /// An event needs a day to sit on; a task does not.
    private var isDated: Bool { item.dueDate != nil }

    private func links(_ kind: LinkKind) -> [LinkTemplate] {
        links.filter { $0.kind == kind }
    }

    var body: some View {
        Section("As a task") {
            Button("Send to Reminders…") { onSend([item], .reminders) }
            Button("Save as .csv…") { onSend([item], .csvFile) }
            // Never disabled: with nothing saved yet this submenu is the only
            // place that says a tracker is possible at all.
            Menu(LinkKind.task.menuTitle) {
                ForEach(trackers) { preset in
                    Button(preset.name) { onOpenPreset(item, preset) }
                }
                linkEntries(.task, hasBuiltIns: !trackers.isEmpty)
            }
        }
        Section("As an event") {
            Button("Save as .ics…") { onSend([item], .icsFile) }
                .disabled(!isDated)
            Button("Add to Calendar…") { onSend([item], .calendar) }
                .disabled(!isDated)
            Menu(LinkKind.event.menuTitle) {
                ForEach(services) { service in
                    Button(service.title) { onOpenWeb(item, service) }
                }
                linkEntries(.event, hasBuiltIns: !services.isEmpty)
            }
            .disabled(!isDated)
        }
    }

    @ViewBuilder
    private func linkEntries(_ kind: LinkKind, hasBuiltIns: Bool) -> some View {
        let saved = links(kind)
        if !saved.isEmpty, hasBuiltIns {
            Divider()
        }
        ForEach(saved) { link in
            Button(link.name) { onOpenLink(item, link) }
        }
        if !saved.isEmpty || hasBuiltIns {
            Divider()
        }
        Button(kind.addTitle) { onManageLinks(kind) }
    }
}

/// The row's export affordance: a badge once it has been sent somewhere, a
/// quiet hint while the pointer is over a row that has not.
///
/// It used to be a label. It looked clickable, people clicked it, nothing
/// happened — so now it is the control it was pretending to be.
///
/// It is always laid out, and only its opacity changes on hover. Appearing and
/// disappearing is what made rows grow and their timecodes slide sideways as the
/// pointer crossed them; a `Menu`'s intrinsic height is its own business, so the
/// only reliable way to keep a row still is to never change what is in it.
struct ExportControl: View {
    let item: ComposedItem
    let isRowHovered: Bool
    let destinations: ExportDestinations

    @Environment(\.pikoTheme) private var theme
    @State private var isHovered = false

    /// Past two destinations the badges stop being labels and start being a
    /// wall, so they collapse into a count. Which ones is still one click away.
    private static let badgeLimit = 2

    /// An exported row says so at all times; an untouched one only offers itself
    /// to a pointer that is already on the row.
    private var isVisible: Bool { item.isExported || isRowHovered }

    var body: some View {
        Menu {
            destinations
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isVisible ? 1 : 0)
        // Off with the opacity, which also takes the tooltip and the hover
        // highlight with it — an invisible control must be inert, not just pale.
        .allowsHitTesting(isVisible)
        .onHover { isHovered = $0 }
        .help(item.isExported ? helpText : "Send this item")
    }

    private var helpText: String {
        item.exports
            .map { ExportKey.badge($0.target, links: destinations.links) }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var label: some View {
        if item.exports.count > Self.badgeLimit {
            chip(icon: "arrow.up.forward", text: "Sent ×\(item.exports.count)", sent: true)
        } else if item.isExported {
            HStack(spacing: 4) {
                ForEach(item.exports, id: \.target) { record in
                    chip(icon: ExportKey.icon(record.target),
                         text: ExportKey.badge(record.target, links: destinations.links),
                         sent: true)
                }
            }
        } else {
            chip(icon: "arrow.up.forward", text: "Send", sent: false)
        }
    }

    /// Quiet by default, lit on hover — the highlight is what says "this is a
    /// control", and the colour still reads as metadata beside the content.
    private func chip(icon: String, text: String, sent: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        .foregroundStyle(sent ? theme.positive : theme.dim)
        .background(background(sent), in: RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(sent ? theme.positive.opacity(isHovered ? 0.6 : 0.35) : theme.line,
                              lineWidth: 1)
        )
    }

    private func background(_ sent: Bool) -> Color {
        guard isHovered else { return .clear }
        return sent ? theme.positive.opacity(0.12) : theme.card2
    }
}
