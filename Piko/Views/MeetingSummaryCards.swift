import AppKit
import SwiftUI

/// The summary itself: brief, the full read behind Expand, decisions, action
/// items and open questions.
///
/// Everything here is editable. What the model produced lives in summary.json
/// and is never touched; corrections, ticks and exports go into an overlay
/// (see SummaryEdits), and this view renders the composition of the two — so a
/// rerun of the summarizer cannot destroy what the user changed.
///
/// Every timecode is a real transcript position, not something the model wrote
/// — see src/piko/skills/meeting/summary.py. Tapping one seeks the recording,
/// which is the whole point of PRODUCT.md's verifiability promise.
struct MeetingSummaryCards: View {
    let summary: ComposedSummary
    @Bindable var meeting: MeetingVM
    /// Jump the player to a moment in the recording.
    var onSeek: ((Double) -> Void)?
    /// Open the review sheet for these rows, on that destination. Writing into
    /// Reminders or Calendar is outward-facing, so it never happens straight
    /// from a row.
    var onSend: (([ComposedItem], TaskExporter.Target) -> Void)?

    @Environment(\.pikoTheme) private var theme
    @State private var isSummaryExpanded = false
    /// Calendar services Piko does not know about, added by the user.
    @State private var customLinks: [CustomCalendarLink] = []
    @State private var services = WebCalendarVisibility.visible
    @State private var isEditingLinks = false
    /// The row the pointer is over, so its send and edit affordances appear.
    @State private var hoveredRow: String?
    /// The row being edited, and the draft it is holding. One at a time: two
    /// half-finished edits on screen is a state nobody asked for.
    @State private var editingRow: String?
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 12) {
            briefCard
            if !summary.decisions.isEmpty { citedCard("Decisions", summary.decisions) }
            actionsCard
            if !summary.openQuestions.isEmpty { citedCard("Open questions", summary.openQuestions) }
        }
        .onAppear { reloadLinks() }
        .sheet(isPresented: $isEditingLinks) {
            CalendarLinksSheet(onChange: reloadLinks)
        }
    }

    static func clockText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Brief, with the long read behind Expand

    private var briefCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "Brief")
                    copyButton { _ in MarkdownExport.brief(summary) }
                    Spacer()
                    if !summary.summary.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isSummaryExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(isSummaryExpanded ? "Collapse" : "Full summary")
                                Image(systemName: isSummaryExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(summary.brief)
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)

                if isSummaryExpanded {
                    Rectangle().fill(theme.line).frame(height: 1)
                    Text(summary.summary)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .foregroundStyle(theme.text)
                        .textSelection(.enabled)
                }

                if !summary.topics.isEmpty {
                    topicChips
                }
            }
        }
    }

    private var topicChips: some View {
        // Wraps rather than clipping: a six-topic meeting overflows one line.
        FlowLayout(spacing: 5) {
            ForEach(summary.topics, id: \.self) { topic in
                Text(topic)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(theme.dim)
            }
        }
    }

    // MARK: - Decisions and open questions

    private func citedCard(_ title: String, _ items: [ComposedItem]) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    SectionLabel(text: title)
                    copyButton { MarkdownExport.section(title, items: items, for: $0) }
                    Spacer()
                }
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        timecode(item.start)
                        itemText(item)
                        if item.isEdited { ItemMarker(text: "edited", filled: true) }
                        Spacer(minLength: 0)
                        editControls(item)
                        moreControl(item)
                    }
                    .padding(.vertical, 2)
                    .onHover { hoveredRow = $0 ? item.id : nil }
                    .contextMenu { rowMenu(item, sendable: false) }
                }
            }
        }
    }

    // MARK: - Action items

    private var actionsCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 0) {
                actionsHeader
                    .padding(.bottom, 6)
                if summary.actionItems.isEmpty {
                    Text("Nothing was committed to out loud. You can still add a task yourself.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                        .padding(.vertical, 4)
                }
                ForEach(summary.actionItems) { item in
                    actionRow(item)
                }
                removedRow
            }
        }
    }

    /// One click on the bin has to be undoable, and this is the whole undo: a
    /// removed item is remembered as removed, not erased.
    @ViewBuilder
    private var removedRow: some View {
        let removed = meeting.removedCount()
        if removed > 0 {
            HStack(spacing: 8) {
                Text("\(removed) removed")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dim)
                Button("Bring back") { meeting.restoreRemoved() }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
            }
            .padding(.top, 8)
        }
    }

    private var openCount: Int {
        summary.actionItems.filter { !$0.isDone }.count
    }

    private var actionsHeader: some View {
        HStack(spacing: 10) {
            SectionLabel(text: "Action items")
            if !summary.actionItems.isEmpty {
                Text("\(openCount) / \(summary.actionItems.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dim)
                copyButton {
                    MarkdownExport.section("Action items", items: summary.actionItems,
                                           for: $0, checkboxes: true)
                }
            }
            Spacer()
            Button("+ Add item") { meeting.addManualItem() }
                .buttonStyle(GhostButtonStyle())
            // One accent action, destination chosen in the sheet: which app a
            // task belongs in depends on the task, not on a setting.
            Button("Send…") { onSend?(summary.actionItems, .icsFile) }
                .buttonStyle(AccentButtonStyle(compact: true))
                .disabled(summary.actionItems.isEmpty)
        }
    }

    private func actionRow(_ item: ComposedItem) -> some View {
        HStack(spacing: 11) {
            DoneCheckbox(isDone: item.isDone) { meeting.toggleDone(item) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    itemText(item)
                    if item.isEdited {
                        ItemMarker(text: "edited", filled: true)
                    } else if item.origin != .generated {
                        ItemMarker(text: item.origin == .manual ? "manual" : "was in the previous version",
                                   filled: false)
                    }
                }
                DueRow(item: item, isRowHovered: hoveredRow == item.id, destinations: destinations(item))
            }
            Spacer(minLength: 8)
            if let owner = item.owner {
                Text(owner)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(theme.text)
            }
            editControls(item)
            timecode(item.start)
            moreControl(item)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
        .onHover { hoveredRow = $0 ? item.id : nil }
        .contextMenu { rowMenu(item, sendable: true) }
    }

    private func itemText(_ item: ComposedItem) -> some View {
        ItemText(item: item,
                 isEditing: editingRow == item.id,
                 draft: $draft,
                 onSave: { save(item) },
                 onCancel: { editingRow = nil })
    }

    /// Edit while reading, save and discard while editing. Shown on hover so a
    /// screen full of rows is not a screen full of buttons.
    @ViewBuilder
    private func editControls(_ item: ComposedItem) -> some View {
        if editingRow == item.id {
            HStack(spacing: 2) {
                RowIconButton(icon: "xmark", help: "Discard the change (Esc)") {
                    editingRow = nil
                }
                RowIconButton(icon: "checkmark", help: "Save (Enter)", tint: theme.accent) {
                    save(item)
                }
            }
        } else if hoveredRow == item.id {
            RowIconButton(icon: "pencil",
                          help: "Change the wording — the model's original is kept") {
                startEditing(item)
            }
        }
    }

    /// Everything destructive or rare, one step behind a menu — and far from
    /// the pencil. A bare bin next to the edit button was hit by accident
    /// within a minute of shipping it; an undo does not make that acceptable.
    @ViewBuilder
    private func moreControl(_ item: ComposedItem) -> some View {
        if hoveredRow == item.id, editingRow != item.id {
            RowMenuButton {
                rowMenu(item, sendable: false)
            }
            .padding(.leading, 12)
        }
    }

    /// Copy the card as Markdown. Every generated block gets one: reading a
    /// summary and then retyping it into a chat is not a workflow.
    @ViewBuilder
    private func copyButton(_ text: @escaping (MeetingRecording) -> String) -> some View {
        if let recording = meeting.selected {
            CopyButton(text: { text(recording) })
        }
    }

    private func reloadLinks() {
        customLinks = CustomCalendarLinkStore.load()
        services = WebCalendarVisibility.visible
    }

    private func startEditing(_ item: ComposedItem) {
        draft = item.text
        editingRow = item.id
    }

    private func save(_ item: ComposedItem) {
        meeting.setText(draft, for: item)
        editingRow = nil
    }

    /// The destinations, built once and used by both the right-click menu and
    /// the badge on the row.
    private func destinations(_ item: ComposedItem) -> ExportDestinations {
        ExportDestinations(item: item,
                           customLinks: customLinks,
                           services: services,
                           onSend: { onSend?($0, $1) },
                           onOpenWeb: openInWeb,
                           onOpenCustom: openCustom,
                           onAddLink: { isEditingLinks = true })
    }

    @ViewBuilder
    private func rowMenu(_ item: ComposedItem, sendable: Bool) -> some View {
        if sendable {
            destinations(item)
            Divider()
        }
        Button("Edit") { startEditing(item) }
        if item.isEdited {
            Button("Restore generated") { meeting.restoreGenerated(item) }
        }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.text, forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) { meeting.delete(item) }
    }

    /// For the people whose calendar lives in a browser tab rather than in an
    /// account the Mac is signed into. The service's own compose screen opens
    /// prefilled — including guests, which only it is allowed to invite.
    private func openInWeb(_ item: ComposedItem, _ service: WebCalendarLink.Service) {
        guard let recording = meeting.selected,
              let url = WebCalendarLink.url(service, for: item, from: recording,
                                            context: meeting.manualContext(for: recording))
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func openCustom(_ item: ComposedItem, _ link: CustomCalendarLink) {
        guard let recording = meeting.selected,
              let url = link.url(for: item, from: recording,
                                 context: meeting.manualContext(for: recording))
        else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func timecode(_ start: Double?) -> some View {
        if let start {
            if let onSeek {
                Button { onSeek(start) } label: {
                    Timecode(text: Self.clockText(start))
                }
                .buttonStyle(.plain)
                .help("Jump to this moment")
            } else {
                Timecode(text: Self.clockText(start))
            }
        }
    }
}
