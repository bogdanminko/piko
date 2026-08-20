import SwiftUI

/// What the first answer is made of: the two capability cards, the strip that
/// says where that answer came from, and the questions worth asking once there
/// is a model to answer them.
///
/// Split out of `WorkspaceChatView` for length alone — it is one turn's worth
/// of chrome, and the turn it belongs to happens exactly once per session.
extension WorkspaceChatView {
    var capabilityCards: some View {
        HStack(alignment: .top, spacing: 11) {
            ForEach(CapabilityCard.all) { card in
                capabilityCard(card)
            }
        }
    }

    private func capabilityCard(_ card: CapabilityCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Text(card.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(card.detail)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                // What each way out costs. This is the export ladder made
                // visible: the free rungs are marked, the expensive one says
                // why it is expensive.
                FlowLayout(spacing: 5) {
                    ForEach(card.badges) { badge in
                        Text(badge.text)
                            .font(.system(size: 10.5))
                            .foregroundStyle(badge.isFree ? theme.positive : theme.dim)
                            .padding(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                            .background {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill((badge.isFree ? theme.positive : theme.dim)
                                        .opacity(0.13))
                            }
                    }
                }
            }
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 12, trailing: 14))

            Divider().overlay(theme.line)

            HStack(spacing: 9) {
                Text(card.command)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.dim)
                Spacer()
                Button(card.actionTitle) {
                    if card.command == "/summarize" { onRecord() } else { onAttach() }
                }
                .controlSize(.small)
            }
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(theme)
    }

    /// Where the answer above came from, and what is happening behind it.
    ///
    /// The wording is narrower than it is tempting to make it: the model does
    /// not check the written answer, so this never claims it did. It says only
    /// what is true — the answer needed no model, and the model is now up for
    /// the questions that follow.
    var provenanceStrip: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(isModelWarm ? theme.positive : theme.accent)
                .frame(width: 7, height: 7)
            Text(provenanceText)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let seconds = warmupSeconds, isModelWarm {
                Text("model up in \(String(format: "%.1f", seconds)) s")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.dim)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill((isModelWarm ? theme.positive : theme.accent).opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder((isModelWarm ? theme.positive : theme.accent).opacity(0.3))
                }
        }
    }

    private var provenanceText: String {
        if !isModelReady {
            return "This answer was written ahead of time, so it needed no model. "
                + "No summarizer is downloaded yet, so follow-up questions have nowhere to go."
        }
        return isModelWarm
            ? "That answer was written ahead of time. The local model is up now, so "
                + "anything you ask next is answered for real."
            : "This answer was written ahead of time, so it needed no model. "
                + "The real one is loading behind it."
    }

    var followUps: some View {
        FlowLayout(spacing: 7) {
            ForEach(WorkspaceChatVM.followUps, id: \.self) { question in
                Button(question) { chat.send(question) }
                    .buttonStyle(GhostButtonStyle())
                    .controlSize(.small)
            }
        }
    }
}
