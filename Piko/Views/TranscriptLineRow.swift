import SwiftUI

// MARK: - One line

/// A line reads as text until it is clicked, then becomes a field. The whole
/// line rather than the word is the unit: nobody clicks a word to fix a name,
/// they retype the sentence.
struct TranscriptLineRow: View {
    let line: CaptionTranscript.Line
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @State private var editing = false
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Timecode(text: clockText, seconds: line.start)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                if line.isEdited {
                    Text("edited")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accent)
                        .help("The model said: \(line.generated)")
                }
                text
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var text: some View {
        if editing {
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text)
                .lineSpacing(2)
                .focused($focused)
                // Asked for here rather than in the tap that opened it: the
                // field does not exist yet at that point, and AppKit drops a
                // focus request for a view it has not placed — silently, so
                // what you see is a caret still blinking in the chat.
                .onAppear { FieldFocus.take { focused = true } }
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onExitCommand { editing = false }
        } else {
            Text(line.text)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .leading) {
                    if hovering {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.accent.opacity(0.06))
                            .padding(EdgeInsets(top: -3, leading: -5, bottom: -3, trailing: -5))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    draft = line.text
                    editing = true
                }
                .help("Click to correct this line")
        }
    }

    private var clockText: String {
        let total = Int(line.start)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func commit() {
        editing = false
        onCommit(draft)
    }
}
