import SwiftUI

/// The "done" box on an action item.
///
/// It carries the count in the card header, keeps finished work out of the
/// export sheet's pre-selection, and travels to Reminders as a completed task.
/// Its full worth arrives with reading completion back from there — until then
/// it is bookkeeping inside the app.
struct DoneCheckbox: View {
    let isDone: Bool
    let action: () -> Void

    @Environment(\.pikoTheme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isDone ? theme.accent : .clear)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isDone ? .clear : theme.dim, lineWidth: 1.5)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.accentOn)
                }
            }
            .frame(width: 15, height: 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isDone ? "Mark as not done" : "Mark as done")
    }
}
