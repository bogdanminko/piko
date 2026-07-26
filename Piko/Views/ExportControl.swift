import SwiftUI

/// Where a row can be sent, as a menu.
///
/// The same list appears in two places — the row's right-click menu and the
/// badge that says where it already went — so it lives in one view rather than
/// being written twice and drifting.
struct ExportDestinations: View {
    let item: ComposedItem
    let customLinks: [CustomCalendarLink]
    /// Built-in services the user has not hidden.
    let services: [WebCalendarLink.Service]
    let onSend: ([ComposedItem], TaskExporter.Target) -> Void
    let onOpenWeb: (ComposedItem, WebCalendarLink.Service) -> Void
    let onOpenCustom: (ComposedItem, CustomCalendarLink) -> Void
    let onAddLink: () -> Void

    /// An event needs a day to sit on; a reminder does not.
    private var isDated: Bool { item.dueDate != nil }

    var body: some View {
        Button("Save as .ics…") { onSend([item], .icsFile) }
            .disabled(!isDated)
        Button("Add to Calendar…") { onSend([item], .calendar) }
            .disabled(!isDated)
        Menu("Open in web calendar") {
            ForEach(services) { service in
                Button(service.title) { onOpenWeb(item, service) }
            }
            if !customLinks.isEmpty, !services.isEmpty {
                Divider()
                ForEach(customLinks) { link in
                    Button(link.name) { onOpenCustom(item, link) }
                }
            }
            Divider()
            Button("Add calendar link…", action: onAddLink)
        }
        .disabled(!isDated)
        Button("Send to Reminders…") { onSend([item], .reminders) }
    }
}

/// The row's export affordance: a badge once it has been sent somewhere, a
/// quiet hint while the pointer is over a row that has not.
///
/// It used to be a label. It looked clickable, people clicked it, nothing
/// happened — so now it is the control it was pretending to be, and rows with
/// nothing to show still offer a way in on hover instead of hiding the action
/// in a right-click nobody tries.
struct ExportControl: View {
    let item: ComposedItem
    let isRowHovered: Bool
    let destinations: ExportDestinations

    @Environment(\.pikoTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        if item.isExported || isRowHovered {
            Menu {
                destinations
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { isHovered = $0 }
            .help(item.isExported ? "Sent — send again or somewhere else" : "Send this item")
        }
    }

    @ViewBuilder
    private var label: some View {
        if item.isExported {
            HStack(spacing: 4) {
                ForEach(TaskExporter.Target.allCases) { target in
                    if item.export(to: target.rawValue) != nil {
                        badge(target)
                    }
                }
            }
        } else {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .semibold))
                Text("Send")
            }
            .font(.system(size: 10.5))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .foregroundStyle(theme.dim)
            .background(isHovered ? theme.card2 : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5).strokeBorder(theme.line, lineWidth: 1)
            )
        }
    }

    /// Quiet by default, lit on hover — the highlight is what says "this is a
    /// control", and the colour still reads as metadata beside the content.
    private func badge(_ target: TaskExporter.Target) -> some View {
        HStack(spacing: 3) {
            Image(systemName: target == .icsFile
                  ? "doc" : target == .calendar ? "calendar" : "arrow.up.forward")
                .font(.system(size: 8, weight: .semibold))
            Text(target.badge)
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        .foregroundStyle(theme.positive)
        .background(isHovered ? theme.positive.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(theme.positive.opacity(isHovered ? 0.6 : 0.35), lineWidth: 1)
        )
    }
}
