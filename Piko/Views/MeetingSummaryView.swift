import SwiftUI

/// Design stub for the next vertical (see docs/PRODUCT.md). The backend is
/// not implemented yet — this screen previews the planned layout with
/// sample data so the shell design is complete.
struct MeetingSummaryView: View {
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 12) {
                    briefCard
                    decisionsCard
                    actionsCard
                    questionsCard
                }
                transcriptCard
                    .frame(width: 330)
            }
            .opacity(0.55)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
    }

    private var header: some View {
        ScreenHeader(title: "Meeting Summary",
                     subtitle: "Sample preview · summaries you can verify against the recording") {
            HStack(spacing: 10) {
                ComingSoonBadge()
                Button("Export Markdown") {}
                    .buttonStyle(AccentButtonStyle())
                    .disabled(true)
            }
        }
    }

    private var briefCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Brief")
                Text("Discussed the Meeting Summary beta timeline, runtime choice and the eval set. "
                     + "Agreed to keep cloud sync out of v1: metrics first, model tuning second.")
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .foregroundStyle(theme.text)
                HStack(spacing: 5) {
                    ForEach(["Meeting Summary", "Model Runtime", "Eval pipeline", "Release plan"],
                            id: \.self) { topic in
                        Text(topic)
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 2)
                            .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(theme.dim)
                    }
                }
            }
        }
    }

    private var decisionsCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Decisions")
                decisionRow("12:40", "Meeting Summary beta ships August 15")
                decisionRow("21:05", "MLX stays the default runtime, LM Studio becomes an option")
                decisionRow("34:18", "No cloud sync in v1")
            }
        }
    }

    private func decisionRow(_ timecode: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Timecode(text: timecode)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.text)
        }
        .padding(.vertical, 2)
    }

    private var actionsCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Action items")
                    .padding(.bottom, 6)
                actionRow("Collect 30 meeting recordings for the eval set", who: "Anya",
                          due: "by Aug 5", timecode: "27:11")
                actionRow("Extract ModelRuntime into its own protocol", who: "Dima",
                          due: "by Aug 1", timecode: "30:52")
                actionRow("Run three models against groundedness", who: "Mark",
                          due: "no due date", timecode: "44:03")
            }
        }
    }

    private func actionRow(_ text: String, who: String, due: String, timecode: String) -> some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(theme.dim, lineWidth: 1.5)
                .frame(width: 14, height: 14)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.text)
            Spacer(minLength: 8)
            Text(who)
                .font(.system(size: 11.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(theme.text)
            Text(due)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
            Timecode(text: timecode)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private var questionsCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(text: "Open questions")
                questionRow("Who owns the Hugging Face quantizations?", timecode: "46:30")
                questionRow("Do we need JSON export in the first beta?", timecode: "49:12")
            }
        }
    }

    private func questionRow(_ text: String, timecode: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.text)
            Timecode(text: timecode)
        }
    }

    private var transcriptCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    SectionLabel(text: "Transcript")
                    Spacer()
                    Text("source")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                }
                Text("Every item on the left links to its moment in the recording — "
                     + "you can verify the summary without listening to the whole thing.")
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(theme.dim)
                VStack(alignment: .leading, spacing: 0) {
                    transcriptRow("12:38", speaker: "Anya",
                                  text: "Let's lock it in: the Meeting Summary beta is August fifteenth.")
                    transcriptRow("12:44", speaker: "Dima",
                                  text: "We'll make it if we don't start tuning before the eval pipeline.")
                    transcriptRow("18:24", speaker: "Anya",
                                  text: "It matters more that users can verify the summary than that it reads nicely.")
                    transcriptRow("21:05", speaker: "Mark",
                                  text: "MLX stays the default, LM Studio as an option for private servers.")
                    transcriptRow("27:11", speaker: "Anya",
                                  text: "I'll collect thirty recordings by August fifth.")
                    transcriptRow("34:18", speaker: "Dima",
                                  text: "Sync is a separate product, we're not dragging it into v1.")
                }
            }
        }
    }

    private func transcriptRow(_ timecode: String, speaker: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Timecode(text: timecode)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(speaker)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dim)
                Text(text)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(theme.text)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }
}
