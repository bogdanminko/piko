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

    // Not private: the sending and details halves of this view live in their own
    // files (see MeetingSummaryCards+Sending / +Details for why).
    @Environment(\.pikoTheme) var theme
    @State private var isSummaryExpanded = false
    // Where a row can go. Not private, because the sending half of this view
    // lives in MeetingSummaryCards+Sending.swift — see there for why it is its
    // own file.
    /// Calendars and trackers Piko does not know about, added by the user.
    @State var links: [LinkTemplate] = []
    /// The ones that need no setup, minus whatever the user has hidden.
    @State var services: [WebCalendarLink.Service] = []
    @State var trackers: [LinkPreset] = []
    /// Which kind of link is being managed, while the sheet is open.
    @State var editingLinks: LinkKind?
    /// Something worth saying about the last link that was opened — that nothing
    /// answered it, or that the row went to the clipboard because its create
    /// screen takes no URL. Either way said out loud rather than swallowed.
    @State var openNote: OpenNote?

    struct OpenNote: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    /// The row the pointer is over, so its send and edit affordances appear.
    @State var hoveredRow: String?
    /// The row whose assignee/deadline/epic popover is open.
    @State var detailsRow: String?
    /// Whether the meeting-wide epic is being set.
    @State var isEditingEpic = false
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
        .sheet(item: $editingLinks) { kind in
            LinksSheet(kind: kind, onChange: reloadLinks)
        }
        .alert(openNote?.title ?? "", isPresented: Binding(
            get: { openNote != nil },
            set: { if !$0 { openNote = nil } }
        )) {
            Button("OK") { openNote = nil }
        } message: {
            Text(openNote?.message ?? "")
        }
    }

    /// One row-control square, matching `RowIconButton`. The row reserves its
    /// slots from this so nothing shifts when a control fades in.
    static let controlSlot: CGFloat = 22

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
                    copyButton { _ in MarkdownExport.brief(summary) }
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
                    Spacer()
                    copyButton { MarkdownExport.section(title, items: items, for: $0) }
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
            }
            Spacer()
            meetingEpicControl
            Button("+ Add item") { meeting.addManualItem() }
                .buttonStyle(GhostButtonStyle())
            // One accent action, destination chosen in the sheet: which app a
            // task belongs in depends on the task, not on a setting — but it
            // opens on wherever the last send went, since that is the answer
            // most likely to still be right.
            Button("Send…") { onSend?(summary.actionItems, TaskExporter.LastUsed.target) }
                .buttonStyle(AccentButtonStyle(compact: true))
                .disabled(summary.actionItems.isEmpty)
            if !summary.actionItems.isEmpty {
                copyButton {
                    MarkdownExport.section("Action items", items: summary.actionItems,
                                           for: $0, checkboxes: true)
                }
            }
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
                DueRow(item: item, isRowHovered: hoveredRow == item.id,
                       destinations: destinations(item),
                       onEdit: { detailsRow = item.id })
            }
            Spacer(minLength: 8)
            detailsControl(item)
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

    /// Edit while reading, save and discard while editing. Faded rather than
    /// absent while the pointer is elsewhere: a screen full of rows should not be
    /// a screen full of buttons, but a control that appears on hover *moves* the
    /// row it appears in, and every row twitching as the pointer crosses it is
    /// worse than a pale icon. The slot is two buttons wide at all times, which
    /// is what editing needs.
    private func editControls(_ item: ComposedItem) -> some View {
        let isEditing = editingRow == item.id
        return HStack(spacing: 2) {
            if isEditing {
                RowIconButton(icon: "xmark", help: "Discard the change (Esc)") {
                    editingRow = nil
                }
                RowIconButton(icon: "checkmark", help: "Save (Enter)", tint: theme.accent) {
                    save(item)
                }
            } else {
                RowIconButton(icon: "pencil",
                              help: "Change the wording — the model's original is kept") {
                    startEditing(item)
                }
                .opacity(hoveredRow == item.id ? 1 : 0)
                .allowsHitTesting(hoveredRow == item.id)
            }
        }
        .frame(width: Self.controlSlot * 2 + 2, alignment: .trailing)
    }

    /// Everything destructive or rare, one step behind a menu — and far from
    /// the pencil. A bare bin next to the edit button was hit by accident
    /// within a minute of shipping it; an undo does not make that acceptable.
    private func moreControl(_ item: ComposedItem) -> some View {
        let isShown = hoveredRow == item.id && editingRow != item.id
        return RowMenuButton {
            rowMenu(item, sendable: false)
        }
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .padding(.leading, 12)
    }

    /// Copy the card as Markdown. Every generated block gets one: reading a
    /// summary and then retyping it into a chat is not a workflow.
    @ViewBuilder
    private func copyButton(_ text: @escaping (MeetingRecording) -> String) -> some View {
        if let recording = meeting.selected {
            CopyButton(text: { text(recording) })
        }
    }

    private func startEditing(_ item: ComposedItem) {
        draft = item.text
        editingRow = item.id
    }

    private func save(_ item: ComposedItem) {
        meeting.setText(draft, for: item)
        editingRow = nil
    }

    @ViewBuilder
    private func rowMenu(_ item: ComposedItem, sendable: Bool) -> some View {
        if sendable {
            destinations(item)
            Divider()
        }
        Button("Edit") { startEditing(item) }
        // On the list where they mean something. A decision has no owner and no
        // deadline — it already happened.
        if item.list == .actionItems {
            Button("Assignee, due date, epic…") { detailsRow = item.id }
        }
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
