import SwiftUI

/// A session's name, correctable in place.
///
/// Every title Piko shows is generated: a timestamp for a recorded call, the
/// file name for anything imported or captioned. That is a starting point, not
/// an answer — the same weekly call reads as three unrelated things by Friday.
/// So renaming writes back into the record itself (`meta.json` for a meeting,
/// `history.json` for a captions run) rather than keeping a display alias
/// beside it, and every list showing that session picks the new name up on its
/// next scan.
///
/// Editing is entered deliberately — the pencil appears on hover, so a row
/// still reads as text and a stray click cannot rewrite a name. Enter and
/// clicking away commit, Escape abandons, and an empty field is a cancel: a
/// session with no name at all is worse than the generated one.
struct EditableTitle: View {
    let text: String
    @Binding var isEditing: Bool
    var font: Font = .system(size: 13)
    /// Set only where the row dims its title (a captions run whose file moved).
    var color: Color?
    /// Called with a trimmed, non-empty name that differs from the current one.
    let onRename: (String) -> Void

    @Environment(\.pikoTheme) private var theme
    @State private var draft = ""
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            field
        } else {
            label
        }
    }

    private var field: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(theme.text)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.accent))
            .focused($isFocused)
            .onAppear {
                draft = text
                // A tick late, and only into a field that is already placed:
                // asked for now, AppKit drops it and the caret stays in
                // whatever was focused before — usually the workspace composer,
                // which is what made Rename look like it did nothing.
                FieldFocus.take { isFocused = true }
            }
            .onSubmit(commit)
            .onExitCommand { isEditing = false }
            // Clicking away commits, the way a Finder rename does. Escape gets
            // there first by clearing `isEditing`, so the lost focus it causes
            // finds nothing left to save.
            .onChange(of: isFocused) { _, focused in
                if !focused, isEditing { commit() }
            }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(font)
                .foregroundStyle(color ?? theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if isHovered {
                Button { isEditing = true } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.dim)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Rename")
            }
        }
        .onHover { isHovered = $0 }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard !name.isEmpty, name != text else { return }
        onRename(name)
    }
}
