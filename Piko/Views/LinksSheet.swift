import SwiftUI

/// Managing the links a row can be opened in — calendars on one kind, trackers
/// on the other.
///
/// Opened from the same menu that uses them: there is no settings screen for
/// this, and a section holding two URLs would not have earned one. One sheet for
/// both kinds because the work is identical — a URL with holes in it — and
/// splitting it would mean two screens explaining the same idea.
struct LinksSheet: View {
    let kind: LinkKind
    /// Fired whenever the menu's contents change — added, removed or hidden.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.pikoTheme) private var theme
    @State private var links: [LinkTemplate] = []
    @State private var hidden = BuiltInLinkVisibility.hidden
    @State private var name = ""
    @State private var template = ""
    /// The preset being set up, and what has been typed into its fields. Nil
    /// while nobody has picked one.
    @State private var preset: LinkPreset?
    @State private var answers: [String: String] = [:]

    private var saved: [LinkTemplate] { links.filter { $0.kind == kind } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.sheetTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.text)
            Text(kind.blurb)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            if kind == .task { presetPicker }

            VStack(spacing: 4) {
                ForEach(WebCalendarLink.Service.allCases.filter { _ in kind == .event }) { service in
                    builtInRow(id: service.rawValue, title: service.title,
                               note: "built in", isAvailable: true)
                }
                ForEach(LinkPreset.builtIn.filter { $0.kind == kind }) { preset in
                    let installed = BuiltInLinkVisibility.isInstalled(preset)
                    builtInRow(id: preset.visibilityID, title: preset.name,
                               note: installed ? "built in" : "not installed on this Mac",
                               isAvailable: installed)
                }
                ForEach(saved) { link in
                    row(link)
                }
            }

            if let preset { setup(preset) } else { pasteForm }

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
        .onAppear { links = LinkTemplateStore.load() }
    }

    // MARK: - Presets

    /// The trackers Piko knows the URL shape of but not *your* coordinates. Not
    /// destinations — each one becomes an ordinary saved link once its blanks are
    /// filled in. The ones needing nothing are above, already usable.
    private var presetPicker: some View {
        FlowLayout(spacing: 5) {
            ForEach(LinkPreset.configurable.filter { $0.kind == kind }) { option in
                Button {
                    pick(option)
                } label: {
                    Text(option.name)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(preset?.id == option.id ? theme.accent : theme.card2,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(preset?.id == option.id ? theme.accentOn : theme.text)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A preset's blanks, its hint, and Add. The hint is not decoration: Jira's
    /// prefill wants two numeric ids, and a form asking for a number nobody can
    /// locate is worse than no form at all.
    private func setup(_ preset: LinkPreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(preset.fields) { field in
                self.field(field.label, placeholder: field.placeholder, width: 92,
                           text: Binding(
                               get: { answers[field.token] ?? "" },
                               set: { answers[field.token] = $0 }
                           ))
            }
            caption(preset.hint)
            if preset.needsApp {
                caption("Opens the app on this Mac — it has to be installed.")
            }
            Text(preset.resolved(answers))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.accent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { reset() }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Add \(preset.name)") { add(preset) }
                    .buttonStyle(AccentButtonStyle(compact: true))
                    .disabled(!preset.missing(answers).isEmpty)
            }
        }
    }

    // MARK: - Pasting one in

    private var pasteForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            field("Name", placeholder: kind == .event ? "Yandex Calendar" : "Jira", text: $name)
            field("URL", placeholder: kind == .event
                  ? "https://calendar.example.com/new?title=Weekly&from=…"
                  : "https://tracker.example.com/new?summary=…&duedate=…",
                  text: $template)
            parsePreview
            HStack {
                Spacer()
                Button("Add") { addPasted() }
                    .buttonStyle(AccentButtonStyle(compact: true))
                    .disabled(!canAdd)
            }
        }
    }

    /// What the parser made of the pasted link. Shown before saving, because a
    /// wrong reading has to be visible rather than silent — and because seeing
    /// the placeholders once is how anyone learns they can be edited by hand.
    ///
    /// A recognised-but-unusable link gets the reason and, where one exists, the
    /// page that supplies what is missing. Jira is the whole reason that case
    /// exists: pasting a board URL is the obvious thing to try, and "no fields to
    /// fill in here" is a true and useless answer to it.
    @ViewBuilder
    private var parsePreview: some View {
        if LinkTemplateStore.isOpenable(template) {
            if template.contains("{") {
                caption("Using the placeholders you wrote.")
            } else {
                switch reading {
                case .ready(let parsed, let name):
                    VStack(alignment: .leading, spacing: 3) {
                        caption("Read as \(name):")
                        Text(parsed)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(theme.accent)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .copyPaste(let parsed, let service, _):
                    VStack(alignment: .leading, spacing: 5) {
                        caption("Read as \(service). Its create screen takes no details through a "
                                + "URL, so this opens it and puts the row on your clipboard — one "
                                + "paste on the other side.")
                        Text(parsed)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(theme.accent)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        caption("To have it filled in properly instead: open that address, pick the "
                                + "project and issue type, press Next, and paste the address you "
                                + "land on — it carries the two numbers Jira needs.")
                        if let match = LinkPreset.named(service) {
                            Button("Enter the numbers by hand") { pick(match) }
                                .buttonStyle(GhostButtonStyle())
                        }
                    }
                case .incomplete(let service, let why, let next, _):
                    VStack(alignment: .leading, spacing: 5) {
                        caption(why)
                        HStack(spacing: 8) {
                            if let next {
                                Button("Open \(service)") { NSWorkspace.shared.open(next) }
                                    .buttonStyle(GhostButtonStyle())
                            }
                            // Straight into the form, with the part of the link
                            // that *was* readable already answered.
                            if let match = LinkPreset.named(service) {
                                Button("Fill in by hand") { pick(match) }
                                    .buttonStyle(GhostButtonStyle())
                            }
                        }
                    }
                case .unrecognised:
                    caption("No fields to fill in here — add them yourself from the list below, or "
                            + "paste a link that already has a title and a date in it.")
                }
            }
        }
    }

    /// Parsed once per keystroke and shared by the preview and the Add button, so
    /// what is shown and what would be saved cannot disagree.
    private var reading: LinkParser.Reading {
        LinkParser.read(template, kind: kind)
    }

    /// A hand-written template is taken as-is; anything else has to have been
    /// understood. Add stays off for a recognised-but-unusable link — saving it
    /// would produce a menu entry that opens the wrong page.
    private var canAdd: Bool {
        guard LinkTemplateStore.isOpenable(template) else { return false }
        return template.contains("{") || reading.draft != nil
    }

    // MARK: - Rows

    /// The destinations that ship ready to use: nothing to fill in, click and the
    /// service's own screen opens. They are hidden, not deleted — turning Google
    /// back on should not mean typing a URL.
    ///
    /// An app that is not installed is shown and switched off rather than left
    /// out: "Piko has no Things support" and "Things is not on this Mac" are
    /// different sentences, and only one of them is true.
    private func builtInRow(id: String, title: String,
                            note: String, isAvailable: Bool) -> some View {
        let isVisible = !hidden.contains(id) && isAvailable
        return HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(isVisible ? theme.text : theme.dim)
            Text(note)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.dim)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { isVisible },
                set: { shown in
                    BuiltInLinkVisibility.setHidden(id, !shown)
                    hidden = BuiltInLinkVisibility.hidden
                    onChange()
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(!isAvailable)
            .help(isVisible ? "Hide it from the menu" : "Show it in the menu")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
        .opacity(isVisible ? 1 : 0.55)
    }

    private func row(_ link: LinkTemplate) -> some View {
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
                links = LinkTemplateStore.remove(link)
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

    // MARK: - Pieces

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var placeholderHelp: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(LinkTemplate.placeholders(for: kind), id: \.token) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.token)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .frame(width: 92, alignment: .leading)
                    Text(entry.meaning)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
    }

    private func field(_ label: String, placeholder: String, width: CGFloat = 42,
                       text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
                .frame(width: width, alignment: .leading)
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

    // MARK: - Adding

    /// Opening a preset's form. Whatever the pasted link already said about this
    /// same service is carried in, so nobody retypes the address of their own
    /// Jira after Piko has just read it off their clipboard.
    private func pick(_ option: LinkPreset) {
        answers = reading.prefill(for: option)
        preset = option
        name = option.name
    }

    private func add(_ preset: LinkPreset) {
        links = LinkTemplateStore.add(name: name.isEmpty ? preset.name : name,
                                      kind: kind,
                                      template: preset.resolved(answers))
        onChange()
        reset()
    }

    /// A pasted link is parsed; one that already has placeholders is taken as
    /// written. The name falls back to the service the parser recognised, so the
    /// common path is paste and press Add.
    private func addPasted() {
        var ready = template
        var title = name
        var copiesText = false
        if !template.contains("{"), let draft = reading.draft {
            ready = draft.template
            copiesText = draft.copiesText
            if title.isEmpty { title = draft.name }
        }
        if title.isEmpty {
            title = LinkParser.suggestedName(from: template, kind: kind)
        }
        links = LinkTemplateStore.add(name: title, kind: kind, template: ready,
                                      copiesText: copiesText)
        onChange()
        reset()
    }

    private func reset() {
        preset = nil
        answers = [:]
        name = ""
        template = ""
    }
}
