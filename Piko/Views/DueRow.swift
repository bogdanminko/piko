import SwiftUI

/// The line under an action item: the resolved date, the phrase it came from,
/// and where the row has been sent.
///
/// Both halves of the deadline stay on screen — the spoken phrase is the
/// evidence, the date is what the backend made of it.
struct DueRow: View {
    let item: ComposedItem
    let isRowHovered: Bool
    let destinations: ExportDestinations
    /// Open the row's editor. The deadline is the field most often wrong — a
    /// model resolving "end of the week" against the wrong week — so the date
    /// itself is the control, not something beside it.
    var onEdit: (() -> Void)?

    @Environment(\.pikoTheme) private var theme

    /// The resolved date, the phrase it came from, and where the row went.
    /// Both halves stay on screen: the phrase is the evidence, the date is a
    /// suggestion the backend derived from it.
    var body: some View {
        HStack(spacing: 8) {
            Button { onEdit?() } label: { dateLabel }
                .buttonStyle(.plain)
                .disabled(onEdit == nil)
                .help("Set the deadline")
            if let due = item.due, !due.isEmpty {
                Text("« \(due) »")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
            }
            ExportControl(item: item, isRowHovered: isRowHovered, destinations: destinations)
        }
    }

    @ViewBuilder
    private var dateLabel: some View {
        if let label = DueDate.label(item.dueDate, time: item.dueTime) {
            Text(label)
                .font(.system(size: 11.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(theme.text)
        } else {
            // "no due date" is information: nobody committed to one. It stays
            // the wording even though it is now a button — "add a date" would
            // read as a task the summary had left unfinished.
            Text(item.due?.isEmpty == false ? "date not resolved" : "no due date")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
        }
    }
}
