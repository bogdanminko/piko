import SwiftUI

/// Managing the custom "open in web calendar" links.
///
/// Opened from the same menu that uses them — there is no settings screen for
/// this, and a section holding two URLs would not have earned one.
struct CalendarLinksSheet: View {
    /// Fired whenever the menu's contents change — added, removed or hidden.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.pikoTheme) private var theme
    @State private var links: [CustomCalendarLink] = []
    @State private var hidden = WebCalendarVisibility.hidden
    @State private var name = ""
    @State private var template = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendar links")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Paste a link your calendar produced for creating an event — Piko reads it and "
                 + "works out which part is the title, the date and the guests. No account, no "
                 + "access to the calendar itself.")
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                ForEach(WebCalendarLink.Service.allCases) { service in
                    builtInRow(service)
                }
                ForEach(links) { link in
                    row(link)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                field("Name", placeholder: "Yandex Calendar", text: $name)
                field("URL", placeholder: "https://calendar.example.com/new?title=Weekly&from=…",
                      text: $template)
                parsePreview
                HStack {
                    Spacer()
                    Button("Add") { add() }
                        .buttonStyle(AccentButtonStyle(compact: true))
                        .disabled(!template.lowercased().hasPrefix("http"))
                }
            }

            placeholderHelp

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
        .frame(width: 560)
        .background(theme.pane)
        .onAppear { links = CustomCalendarLinkStore.load() }
    }

    /// The services that ship with the app. They are hidden, not deleted —
    /// turning Google back on should not mean typing a URL.
    private func builtInRow(_ service: WebCalendarLink.Service) -> some View {
        let isVisible = !hidden.contains(service.rawValue)
        return HStack(spacing: 10) {
            Text(service.title)
                .font(.system(size: 12.5))
                .foregroundStyle(isVisible ? theme.text : theme.dim)
            Text("built in")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.dim)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { isVisible },
                set: { shown in
                    WebCalendarVisibility.setHidden(service, !shown)
                    hidden = WebCalendarVisibility.hidden
                    onChange()
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(isVisible ? "Hide it from the menu" : "Show it in the menu")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
        .opacity(isVisible ? 1 : 0.55)
    }

    private func row(_ link: CustomCalendarLink) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(link.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text)
                Text(link.template)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                links = CustomCalendarLinkStore.remove(link)
                onChange()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.dim)
            }
            .buttonStyle(.plain)
            .help("Remove this link")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    /// What the parser made of the pasted link. Shown before saving, because a
    /// wrong reading has to be visible rather than silent — and because seeing
    /// the placeholders once is how anyone learns they can be edited by hand.
    @ViewBuilder
    private var parsePreview: some View {
        if template.lowercased().hasPrefix("http") {
            if template.contains("{") {
                caption("Using the placeholders you wrote.")
            } else if let parsed = CalendarLinkParser.template(from: template) {
                VStack(alignment: .leading, spacing: 3) {
                    caption("Piko read it as:")
                    Text(parsed)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                caption("No fields to fill in here — add them yourself from the list below, or "
                        + "paste a link that already has a title and a date in it.")
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var placeholderHelp: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(CustomCalendarLink.placeholders, id: \.token) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.token)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .frame(width: 92, alignment: .leading)
                    Text(entry.meaning)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.dim)
                }
            }
        }
        .padding(.top, 2)
    }

    private func field(_ label: String, placeholder: String,
                       text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
                .frame(width: 42, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: label == "URL" ? .monospaced : .default))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line, lineWidth: 1)
                )
        }
    }

    /// A pasted link is parsed; one that already has placeholders is taken as
    /// written. The name falls back to the service's own, so the common path is
    /// paste and press Add.
    private func add() {
        let ready = template.contains("{")
            ? template
            : (CalendarLinkParser.template(from: template) ?? template)
        let title = name.isEmpty ? CalendarLinkParser.suggestedName(from: template) : name
        links = CustomCalendarLinkStore.add(name: title, template: ready)
        onChange()
        name = ""
        template = ""
    }
}
