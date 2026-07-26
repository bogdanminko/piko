import SwiftUI

/// Copy, with the one thing a copy button owes you: proof it happened.
///
/// The clipboard is invisible. Without the icon flipping to a checkmark for a
/// moment, the only way to know the click registered is to go and paste
/// somewhere — so people click twice and still are not sure.
struct CopyButton: View {
    /// Built lazily: the text is only rendered when the button is pressed.
    let text: () -> String
    var help = "Copy as Markdown"

    @Environment(\.pikoTheme) private var theme
    @State private var hasCopied = false

    var body: some View {
        RowIconButton(icon: hasCopied ? "checkmark" : "doc.on.doc",
                      help: hasCopied ? "Copied" : help,
                      tint: hasCopied ? theme.positive : nil) {
            MarkdownExport.copy(text())
            withAnimation(.easeOut(duration: 0.12)) { hasCopied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.easeOut(duration: 0.2)) { hasCopied = false }
            }
        }
    }
}
