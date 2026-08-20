import SwiftUI

/// The sidebar's list of conversations.
///
/// This replaced Recent, and the replacement is the point. Recent listed
/// *artifacts* — a recording here, a captioned video there — which made the
/// sidebar a second Library and left the thing you were actually in unnamed and
/// unreachable. What a chat app's sidebar lists is chats; the artifacts belong
/// to them, and the Library is where you go looking for one by itself.
///
/// It is also what retires the "Reopen" pill the workspace header used to
/// carry. That button existed because there was one session and no way back
/// into it once you had wandered off. With the conversations listed, going back
/// is where going anywhere already is.
struct SidebarSessions: View {
    enum Layout {
        /// Rows with a title, in the expanded sidebar.
        case list
        /// Icon-only buttons, in the collapsed rail.
        case rail
    }

    let layout: Layout
    @Bindable var store: SessionStore
    @Bindable var appState: AppState

    @Environment(\.pikoTheme) private var theme
    /// The row whose name is being edited. Rows are built by a function, so the
    /// one editing state lives here rather than in each of them.
    @State private var renamingID: ChatSession.ID?

    var body: some View {
        switch layout {
        case .list:
            VStack(alignment: .leading, spacing: 1) {
                ForEach(store.sessions) { session in
                    row(session)
                }
            }
        case .rail:
            VStack(spacing: 6) {
                ForEach(store.sessions.prefix(5)) { session in
                    railButton(session)
                }
            }
        }
    }

    /// The one accent pill in the sidebar belongs to whatever you are looking
    /// at. On Library or Models that is the nav row, so the open conversation
    /// steps down to the quieter "loaded" state rather than competing with it.
    private func isCurrent(_ session: ChatSession) -> Bool {
        store.currentID == session.id
    }

    private func isActive(_ session: ChatSession) -> Bool {
        isCurrent(session) && appState.screen == .artifact
    }

    private func open(_ session: ChatSession) {
        store.select(session)
        appState.screen = .artifact
    }

    // MARK: - Expanded row

    /// A real `Button`, not an `onTapGesture` on a stack.
    ///
    /// The gesture version did not fire at all here — a row read as clickable
    /// and did nothing, which is the worst kind of broken because it looks
    /// fine. A Button also gets an AXPress action and a name, so the row is
    /// reachable by keyboard and by VoiceOver rather than being a picture of a
    /// row.
    ///
    /// The name is drawn *over* that button rather than inside its label, and
    /// that is not a detail. A Button's label is not a place interactive views
    /// work: the row swallowed the hover pencil's click and opened the session
    /// instead, and `.disabled` while renaming — which reaches every view in
    /// the label, a text field included — left a field that could not take the
    /// caret at all, so typing went on landing in the chat composer. The ⋯ menu
    /// sits over the button for the same reason.
    private func row(_ session: ChatSession) -> some View {
        let active = isActive(session)
        let renaming = renamingID == session.id
        return Button {
            // Mid-rename a click belongs to the field: switching away would
            // throw the edit out along with the row. Guarded here rather than
            // with `.disabled`, which would also grey the row out.
            if !renaming { open(session) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon(session))
                    .font(.system(size: 11))
                    .foregroundStyle(active ? theme.accentOn : theme.dim)
                    .frame(width: 16)
                // The title's slot, held open so the icon, the dot and the ⋯
                // keep their places. What is drawn in it is `titleLayer`, and
                // the field it turns into is taller than the text it replaces —
                // the row makes that room rather than letting it spill over the
                // rows next door.
                Color.clear.frame(height: renaming ? 22 : 18)
                if isCurrent(session), !active {
                    Circle().fill(theme.accent).frame(width: 5, height: 5)
                }
                // Reserve the menu's width so the title does not reflow when it
                // appears, and so nothing sits underneath it.
                Color.clear.frame(width: 18, height: 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background(session), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay { titleLayer(session) }
        .overlay(alignment: .trailing) {
            sessionMenu(session).padding(.trailing, 10)
        }
        .accessibilityLabel(session.title)
    }

    /// The name, laid out to the same measurements as the row underneath it —
    /// the icon's width and the menu's width as spacers, not as offsets, so the
    /// two layers cannot drift apart.
    ///
    /// `Spacer` rather than `Color.clear` for those slots: a spacer takes no
    /// clicks, so everything except the name itself still reaches the row.
    private func titleLayer(_ session: ChatSession) -> some View {
        let active = isActive(session)
        let renaming = renamingID == session.id
        return HStack(spacing: 9) {
            Spacer().frame(width: 16)
            EditableTitle(
                text: session.title,
                isEditing: Binding(get: { renamingID == session.id },
                                   set: { renamingID = $0 ? session.id : nil }),
                font: .system(size: 12.5),
                color: active ? theme.accentOn : theme.text,
                onRename: { session.rename(to: $0) }
            )
            .contentShape(Rectangle())
            // This layer is above the button, so the button never sees a click
            // that lands on the name. Clicking a name is clicking its row.
            .onTapGesture { if !renaming { open(session) } }
            Spacer(minLength: 0)
            Spacer().frame(width: 18)
        }
        .padding(.horizontal, 10)
    }

    private func background(_ session: ChatSession) -> Color {
        if isActive(session) { return theme.accent }
        return isCurrent(session) ? theme.card2 : .clear
    }

    /// What the conversation is about, said by its icon: a call, a clip, or
    /// nothing yet.
    private func icon(_ session: ChatSession) -> String {
        if session.meetingID != nil { return "waveform" }
        if session.processor.videoURL != nil { return "film" }
        return "bubble.left"
    }

    /// Deleting forgets the conversation, never the artifact. A recording's
    /// folder and a captioned video both outlive the thread that made them, and
    /// both are still in the Library afterwards — which is why this one is not
    /// behind a confirm and the Library's meeting delete is.
    private func sessionMenu(_ session: ChatSession) -> some View {
        Menu {
            Button("Rename") { renamingID = session.id }
            Button(role: .destructive) {
                store.delete(session)
            } label: {
                Label("Delete Chat", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11))
                .foregroundStyle(isActive(session) ? theme.accentOn : theme.dim)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Collapsed rail

    private func railButton(_ session: ChatSession) -> some View {
        let active = isActive(session)
        return Button {
            open(session)
        } label: {
            Image(systemName: icon(session))
                .font(.system(size: 12))
                .foregroundStyle(active ? theme.accentOn : theme.dim)
                .frame(width: 30, height: 30)
                .background(background(session), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.title)
    }
}
