import SwiftUI

/// The half of an action row the model cannot fill in: who owns it, when it is
/// really due, and which epic it goes under.
///
/// Split out of the cards for the same reason sending was — one closed idea, and
/// the view was long enough without it. See ItemDetailsPopover for why the three
/// are answered together, and SummaryEdits for how an answer survives a rerun of
/// the summarizer.
extension MeetingSummaryCards {
    /// The right-hand cluster on an action row: the assignee, the epic, and the
    /// way into editing either.
    ///
    /// A chip rather than a label, because that is what it always was pretending
    /// to be — the owner has been on screen since the first version of this
    /// screen and there was no way to change it, which is the bug this fixes.
    /// An unowned row shows its slot only under the pointer: a page of "+ who?"
    /// reads as a page of unfinished work, and most rows genuinely have no owner.
    @ViewBuilder
    func detailsControl(_ item: ComposedItem) -> some View {
        // Also while its own popover is open: the popover is anchored to this
        // chip, and letting the pointer wander off the row must not pull the
        // anchor out from under it.
        let isShown = item.owner != nil || item.epic != nil
            || hoveredRow == item.id || detailsRow == item.id
        Button { detailsRow = item.id } label: {
            HStack(spacing: 4) {
                if let epic = item.epic {
                    // Faded when it belongs to the whole meeting rather than to
                    // this row: the same key on every line should read as one
                    // answer, not as twelve.
                    chip(epic, monospaced: true, muted: item.isEpicInherited)
                }
                chip(item.owner ?? "+ who?", monospaced: false, muted: item.owner == nil)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .help("Assignee, deadline and epic")
        .popover(isPresented: Binding(
            get: { detailsRow == item.id },
            set: { if !$0 { detailsRow = nil } }
        ), arrowEdge: .bottom) {
            detailsPopover(item)
        }
    }

    func detailsPopover(_ item: ComposedItem) -> some View {
        ItemDetailsPopover(
            item: item,
            defaultEpic: summary.defaultEpic,
            suggestions: summary.actionItems.compactMap(\.owner),
            onSave: { owner, date, time, epic in
                meeting.setOwner(owner, for: item)
                meeting.setDue(date: date, time: time, for: item)
                meeting.setEpic(epic, for: item)
            },
            onClose: { detailsRow = nil }
        )
    }

    /// The epic for the whole call, on the card's header.
    ///
    /// It sits there rather than on every row because that is where it is true:
    /// the tasks agreed on one planning call go under one epic, and stating it
    /// twelve times is the work the default exists to remove. A row that belongs
    /// somewhere else says so on the row.
    var meetingEpicControl: some View {
        Button { isEditingEpic = true } label: {
            chip(summary.defaultEpic ?? "+ epic", monospaced: summary.defaultEpic != nil,
                 muted: summary.defaultEpic == nil)
        }
        .buttonStyle(.plain)
        .help("The epic every action item from this meeting starts under")
        .popover(isPresented: $isEditingEpic, arrowEdge: .bottom) {
            MeetingEpicEditor(epic: summary.defaultEpic) { typed in
                meeting.setDefaultEpic(typed)
                isEditingEpic = false
            }
        }
    }

    private func chip(_ text: String, monospaced: Bool, muted: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, design: monospaced ? .monospaced : .default))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(muted ? Color.clear : theme.card2, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(muted ? theme.line : .clear, lineWidth: 1)
            )
            .foregroundStyle(muted ? theme.dim : theme.text)
    }
}

/// One field, because there is one question: which epic do this call's tasks
/// belong to. Cleared by emptying it — rows that stated their own keep theirs.
struct MeetingEpicEditor: View {
    let epic: String?
    let onSave: (String?) -> Void

    @Environment(\.pikoTheme) private var theme
    @State private var draft: String

    init(epic: String?, onSave: @escaping (String?) -> Void) {
        self.epic = epic
        self.onSave = onSave
        _draft = State(initialValue: epic ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Epic for this meeting")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text)
            TextField("PROJ-123", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line, lineWidth: 1))
                .onSubmit { onSave(draft) }
            Text("Every action item here starts under it. It reaches Jira's own field when the "
                 + "saved link was set up with one, and the description either way.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { onSave(draft) }
                    .buttonStyle(AccentButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
