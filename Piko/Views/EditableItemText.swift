import SwiftUI

/// An item's text in one of its two states: read, or being edited.
///
/// It used to be a live text field at all times, which read as plain text and
/// yet could be changed by a stray click — the worst of both. Editing is now
/// entered and left deliberately, and the draft lives in the row so the Save
/// button beside it commits the same string the field is showing.
struct ItemText: View {
    let item: ComposedItem
    let isEditing: Bool
    @Binding var draft: String
    /// Enter commits, Escape abandons — the field's own shortcuts, so the
    /// buttons beside it are a second way in rather than the only one.
    let onSave: () -> Void
    let onCancel: () -> Void

    @Environment(\.pikoTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.card2, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(theme.accent, lineWidth: 1)
                )
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onSubmit(onSave)
                .onExitCommand(perform: onCancel)
        } else {
            Text(item.text)
                .font(.system(size: 13.5))
                .foregroundStyle(item.isDone ? theme.dim : theme.text)
                .strikethrough(item.isDone, color: theme.dim)
                .textSelection(.enabled)
        }
    }
}
