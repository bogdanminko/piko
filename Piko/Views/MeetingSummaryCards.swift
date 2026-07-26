import SwiftUI

/// The summary itself: brief, the full read behind Expand, decisions, action
/// items and open questions.
///
/// Every timecode here is a real transcript position, not something the model
/// wrote — see src/piko/skills/meeting/summary.py. Tapping one seeks the
/// recording, which is the whole point of PRODUCT.md's verifiability promise.
struct MeetingSummaryCards: View {
    let summary: MeetingSummary
    /// Jump the player to a moment in the recording.
    var onSeek: ((Double) -> Void)?

    @Environment(\.pikoTheme) private var theme
    @State private var isSummaryExpanded = false

    var body: some View {
        VStack(spacing: 12) {
            briefCard
            if !summary.decisions.isEmpty { decisionsCard }
            if !summary.actionItems.isEmpty { actionsCard }
            if !summary.openQuestions.isEmpty { questionsCard }
        }
    }

    static func clockText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Brief, with the long read behind Expand

    private var briefCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "Brief")
                    Spacer()
                    if !summary.summary.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isSummaryExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(isSummaryExpanded ? "Collapse" : "Full summary")
                                Image(systemName: isSummaryExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(summary.brief)
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)

                if isSummaryExpanded {
                    Rectangle().fill(theme.line).frame(height: 1)
                    Text(summary.summary)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .foregroundStyle(theme.text)
                        .textSelection(.enabled)
                }

                if !summary.topics.isEmpty {
                    topicChips
                }
            }
        }
    }

    private var topicChips: some View {
        // Wraps rather than clipping: a six-topic meeting overflows one line.
        FlowLayout(spacing: 5) {
            ForEach(summary.topics, id: \.self) { topic in
                Text(topic)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(theme.dim)
            }
        }
    }

    // MARK: - Cited lists

    private var decisionsCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Decisions")
                ForEach(summary.decisions) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        timecode(item.start)
                        Text(item.text)
                            .font(.system(size: 13.5))
                            .foregroundStyle(theme.text)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var actionsCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Action items")
                    .padding(.bottom, 6)
                ForEach(summary.actionItems) { item in
                    actionRow(item)
                }
            }
        }
    }

    private func actionRow(_ item: MeetingSummary.Item) -> some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(theme.dim, lineWidth: 1.5)
                .frame(width: 14, height: 14)
            Text(item.text)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.text)
            Spacer(minLength: 8)
            if let owner = item.owner {
                Text(owner)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(theme.text)
            }
            // "no due date" is information: it means nobody committed to one.
            Text(item.due ?? "no due date")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
            timecode(item.start)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private var questionsCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Open questions")
                ForEach(summary.openQuestions) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.text)
                            .font(.system(size: 13.5))
                            .foregroundStyle(theme.text)
                        timecode(item.start)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func timecode(_ start: Double) -> some View {
        if let onSeek {
            Button { onSeek(start) } label: {
                Timecode(text: Self.clockText(start))
            }
            .buttonStyle(.plain)
            .help("Jump to this moment")
        } else {
            Timecode(text: Self.clockText(start))
        }
    }
}

/// Chips that wrap onto the next line instead of being clipped.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        var total = CGSize.zero

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > width, origin.x > 0 {
                origin.x = 0
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            total.width = max(total.width, origin.x - spacing)
            total.height = origin.y + lineHeight
        }
        return total
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var origin = bounds.origin
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.maxX, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
