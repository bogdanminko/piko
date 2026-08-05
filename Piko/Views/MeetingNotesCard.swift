import SwiftUI

/// Somewhere to write things down while the call is happening.
///
/// A transcript records what was said; a note records what mattered — the
/// spelling of a name the ASR will guess at, the deadline that was agreed
/// three sentences before anyone said the word, the thing to remember to do.
/// Both go to the model, and where they disagree the typed line wins, because
/// it is the only input in the pipeline a person actually wrote.
///
/// It sits under `RecordingBar` and therefore appears in both places that bar
/// does — the conversation and the expanded meeting screen. In the
/// conversation there is a thread underneath fighting for the same height, so
/// the list is capped and scrolls rather than growing without limit.
struct MeetingNotesCard: View {
    @Bindable var meeting: MeetingVM
    /// How tall the list may get before it scrolls instead of pushing whatever
    /// is under it off the screen.
    var maxListHeight: CGFloat = 128

    @Environment(\.pikoTheme) private var theme
    @State private var draft = ""
    @State private var editingID: String?
    @State private var editDraft = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case composer
        case row(String)
    }

    var body: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 9) {
                header
                list
                composer
            }
        }
        // The recorder decides which meeting a note belongs to, and it can
        // change under this view — Record pressed while last week's call is
        // open. Asking on every pass is cheap; the file is read only when the
        // answer actually moves.
        .onAppear { meeting.syncNotes() }
        .onChange(of: meeting.notesID) { _, _ in
            meeting.syncNotes()
            editingID = nil
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 9) {
            SectionLabel(text: "Notes")
            if !meeting.notes.isEmpty {
                Text("\(meeting.notes.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dim)
            }
            Spacer(minLength: 8)
            Text("They go to the summary with the transcript")
                .font(.system(size: 11))
                .foregroundStyle(theme.dim)
                .lineLimit(1)
            // The shortcut needs somewhere to live, and a button nobody can see
            // is a shortcut nobody can find.
            RowIconButton(icon: "plus", help: "New note (⌘⇧N)") { focus = .composer }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }

    @ViewBuilder
    private var list: some View {
        if meeting.notes.isEmpty {
            Text("Type what matters as it happens — a name spelled right, a deadline, "
                 + "something to do. Each line is stamped with the second you wrote it.")
                .font(.system(size: 11.5))
                .lineSpacing(2)
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy for the same reason every other list here is: an
                    // hour of a busy call is a lot of rows to lay out to show
                    // four.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(meeting.notes.notes) { note in
                            row(note).id(note.id)
                        }
                    }
                }
                .frame(maxHeight: maxListHeight)
                // Newest is at the bottom, next to the field it was typed in,
                // so the last line written stays in view without scrolling.
                .onChange(of: meeting.notes.count) { _, _ in
                    guard let last = meeting.notes.notes.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func row(_ note: MeetingNote) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Timecode(text: Self.clockText(note.at), seconds: note.at)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 2)
            if editingID == note.id {
                TextField("", text: $editDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.card2, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.accent, lineWidth: 1))
                    .focused($focus, equals: .row(note.id))
                    .onAppear { FieldFocus.take { focus = .row(note.id) } }
                    .onSubmit { commitEdit(note) }
                    .onExitCommand { editingID = nil }
            } else {
                Text(note.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 6)
            if editingID == note.id {
                RowIconButton(icon: "checkmark", help: "Save", tint: theme.accent) {
                    commitEdit(note)
                }
            } else {
                NoteRowActions(
                    onEdit: {
                        editDraft = note.text
                        editingID = note.id
                    },
                    onDelete: { meeting.deleteNote(note) }
                )
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            // The live clock, so what the note will be stamped with is visible
            // before it is written rather than only afterwards.
            NoteClock(recorder: meeting.recorder)
            TextField(meeting.recorder.isActive ? "Note…" : "Add a note…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text)
                .focused($focus, equals: .composer)
                .onSubmit(add)
            Image(systemName: "return")
                .font(.system(size: 10))
                .foregroundStyle(theme.dim)
                .opacity(draft.isEmpty ? 0 : 1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(theme.card2, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line, lineWidth: 1))
        .disabled(!meeting.canTakeNotes)
        .opacity(meeting.canTakeNotes ? 1 : 0.5)
    }

    // MARK: - Actions

    /// Enter adds the line and leaves the caret where it is: notes come in
    /// runs, and reaching for the field again between two of them is how the
    /// second one gets missed.
    private func add() {
        let text = draft
        draft = ""
        meeting.addNote(text)
        focus = .composer
    }

    private func commitEdit(_ note: MeetingNote) {
        meeting.updateNote(note, to: editDraft)
        editingID = nil
    }

    /// "04:12", or an em dash for a note with no moment — an import, or a line
    /// added after the call. A zero there would read as "the very beginning".
    static func clockText(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let total = Int(seconds)
        let hours = total / 3_600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, (total % 3_600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// The second a note typed now would be stamped with.
///
/// Its own view because it changes ten times a second while recording: read
/// from the card's body instead, and every keystroke's worth of notes is laid
/// out again at meter rate for a clock nobody is looking at.
private struct NoteClock: View {
    @Bindable var recorder: MeetingRecorder
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        let seconds = recorder.isActive ? recorder.elapsed : nil
        Text(MeetingNotesCard.clockText(seconds))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(seconds == nil ? theme.dim : theme.accent)
            .frame(width: 38, alignment: .leading)
    }
}

/// Edit and delete, quiet until the pointer is on the row.
///
/// Delete is on the row rather than behind a menu, unlike everywhere else in
/// this app: a note is one line somebody typed seconds ago and can retype, not
/// a recording that took an hour to make.
private struct NoteRowActions: View {
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 2) {
            RowIconButton(icon: "pencil", help: "Edit this note", action: onEdit)
            RowIconButton(icon: "xmark", help: "Delete this note", action: onDelete)
        }
        .opacity(isHovered ? 1 : 0)
        // Hovering an invisible button does not reveal it, so the area they
        // sit in is what listens rather than the buttons themselves.
        .frame(width: 48, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// One note as it appears *inside* a transcript, on the second it was typed.
///
/// Shared by both transcript readings (the docked card and the meeting screen)
/// so a note looks the same wherever the words around it do.
struct TranscriptNoteRow: View {
    let note: MeetingNote

    @Environment(\.pikoTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Timecode(text: MeetingNotesCard.clockText(note.at), seconds: note.at)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 1)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.accent)
                    .padding(.top, 2)
                Text(note.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(theme.card2, in: RoundedRectangle(cornerRadius: 6))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .help("Your note")
    }
}
