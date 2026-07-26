import SwiftUI

/// The quiet tag beside an item's text: "edited", "manual", "was in the
/// previous version".
///
/// Metadata, not status — it says where the row came from and must never
/// compete with what the row says. Filled for a change the user made, outlined
/// for an item that has no model original behind it.
struct ItemMarker: View {
    let text: String
    let filled: Bool

    @Environment(\.pikoTheme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .foregroundStyle(theme.dim)
            .background(filled ? theme.card2 : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(filled ? .clear : theme.line, lineWidth: 1)
            )
    }
}
