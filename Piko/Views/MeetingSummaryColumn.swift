import SwiftUI

/// The left column of the Meeting Summary screen: the summary itself, and
/// everything that happens on the way to it.
///
/// Split out of `MeetingSummaryView` because progress belongs next to the thing
/// being worked on. Both jobs used to report into the transcript card, so
/// pressing Summarize looked like transcription had started instead.
struct MeetingSummaryColumn: View {
    @Bindable var meeting: MeetingVM
    @Bindable var summarizer: SummarizerVM
    let params: [String: Any]

    @Environment(\.pikoTheme) private var theme

    var body: some View {
        if let summary = meeting.summary, !summary.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                toolbar
                ScrollView {
                    MeetingSummaryCards(summary: summary)
                        .padding(.bottom, 8)
                }
                // A rerun keeps the old cards on screen underneath: they are
                // still valid until the new ones land, and blanking them would
                // lose what the user was reading.
                .opacity(meeting.progress(for: .summary) == nil ? 1 : 0.45)
            }
        } else if let progress = meeting.progress(for: .summary) {
            card { running(progress) }
        } else if let failure = meeting.failure(for: .summary) {
            card { failed(failure) }
        } else {
            card { placeholder }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Summary")
                content()
            }
        }
    }

    /// Above the cards once a summary exists: language, rerun, and — during a
    /// rerun — the progress that replaces both.
    @ViewBuilder
    private var toolbar: some View {
        if let progress = meeting.progress(for: .summary) {
            ThemedCard {
                JobProgressRow(percent: progress.percent,
                               message: progress.message,
                               onStop: meeting.cancelWork)
            }
        } else if let recording = meeting.selected {
            HStack {
                if let failure = meeting.failure(for: .summary) {
                    Text(failure)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                        .lineLimit(2)
                }
                Spacer()
                SummaryLanguagePicker(summarizer: summarizer, disabled: meeting.isBusy)
                RerunButton(title: "Rerun summary", disabled: meeting.isBusy) {
                    Task { await meeting.summarize(recording, params: params, force: true) }
                }
            }
        }
    }

    private func running(_ progress: (percent: Double, message: String)) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            JobProgressRow(percent: progress.percent,
                           message: progress.message,
                           onStop: meeting.cancelWork)
            // Named so the first run's silence is explained rather than
            // mistaken for a stall: loading a 4 GB model takes a few seconds.
            Text("Running \(summarizer.selected?.name ?? "the summarizer") on this Mac. "
                 + "Nothing leaves the machine.")
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(theme.dim)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            if let recording = meeting.selected {
                HStack(spacing: 10) {
                    Button("Try again") {
                        Task { await meeting.summarize(recording, params: params, force: true) }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(meeting.isBusy)
                    SummaryLanguagePicker(summarizer: summarizer, disabled: meeting.isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        Text(meeting.transcript == nil
             ? "Record or import a call, then transcribe it. The summary is built "
               + "from the transcript, so it comes after."
             : "Summarize the transcript into decisions, action items and open "
               + "questions — each one linked to the moment it was said.")
            .font(.system(size: 12.5))
            .lineSpacing(3)
            .foregroundStyle(theme.dim)
        if let recording = meeting.selected, meeting.transcript != nil {
            HStack(spacing: 10) {
                Button("Summarize") {
                    Task { await meeting.summarize(recording, params: params) }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(meeting.isBusy)
                SummaryLanguagePicker(summarizer: summarizer, disabled: meeting.isBusy)
            }
        }
    }
}

/// Bar + stage message + Stop, shared by both jobs so they read identically
/// wherever they appear.
struct JobProgressRow: View {
    let percent: Double
    let message: String
    let onStop: () -> Void

    @Environment(\.pikoTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView(value: percent, total: 100)
                .progressViewStyle(.linear)
            HStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button("Stop", action: onStop)
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
        }
    }
}

/// The quiet "do it again" action. It discards work the user already has, so it
/// must not compete with the primary button beside it.
struct RerunButton: View {
    let title: String
    let disabled: Bool
    let action: () -> Void

    @Environment(\.pikoTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(disabled ? theme.dim : theme.accent)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help("Discard the current result and run it again")
    }
}
