import SwiftUI

/// Meeting Summary screen. Recording and transcription are real: the recorder
/// writes a microphone track and a system-audio track, and the backend turns
/// them into a transcript where every line knows which side said it. The
/// summary cards on the left are still a design preview.
struct MeetingSummaryView: View {
    @Bindable var appState: AppState
    @Bindable var meeting: MeetingVM
    /// Whisper/Parakeet model chosen on the Models screen.
    let modelId: String
    /// Whether to tell the far-end voices apart — the Speakers switch on the
    /// Models screen, already checked against the model being on disk.
    let diarize: Bool
    /// Tier, sampling and summary language picked on the Models screen.
    @Bindable var summarizer: SummarizerVM
    /// Rendered as the expanded artifact panel, which has its own way back.
    var embedded = false

    private var summarizerParams: [String: Any] { summarizer.requestParams }

    @Environment(\.pikoTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            RecordingBar(
                recorder: meeting.recorder,
                permissions: meeting.permissions,
                onToggle: { Task { await meeting.toggleRecording(model: modelId, diarize: diarize) } },
                onPauseToggle: meeting.togglePause
            )
            HStack(alignment: .top, spacing: 20) {
                MeetingSummaryColumn(meeting: meeting,
                                     summarizer: summarizer,
                                     params: summarizerParams)
                transcriptCard
                    .frame(width: 380)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
        .onAppear { meeting.refresh() }
    }

    /// The only export control on the screen: one button, with Copy behind a
    /// long-press menu rather than a second button competing with it.
    private var header: some View {
        // Titled after the artifact rather than the feature: this is one
        // reading of a recording inside the workspace, not a screen you
        // navigated to. Hence the way back — and hence its being shut while
        // the recorder is running, since Stop lives on this screen and
        // nowhere else.
        ScreenHeader(title: meeting.selected?.title ?? "Meeting",
                     subtitle: meeting.selected == nil
                         ? "Record a call, get a summary you can verify"
                         : "Summary, decisions and action items you can check against the audio",
                     onBack: embedded ? nil : { appState.show(.none) },
                     backBlockedReason: meeting.recorder.isActive
                         ? "Stop the recording first — Stop is on this screen"
                         : nil,
                     accessory: { exportButton })
    }

    private var exportButton: some View {
        Button("Export Markdown") { exportMarkdown(save: true) }
            .buttonStyle(AccentButtonStyle())
            .disabled(meeting.composed?.isEmpty ?? true)
            .contextMenu {
                Button("Copy as Markdown") { exportMarkdown(save: false) }
            }
    }

    private func exportMarkdown(save: Bool) {
        guard let summary = meeting.composed, let recording = meeting.selected else { return }
        let text = MarkdownExport.make(summary, for: recording)
        if save {
            MarkdownExport.save(text, suggestedName: recording.title)
        } else {
            MarkdownExport.copy(text)
        }
    }

    // MARK: - Transcript

    private var transcriptCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    SectionLabel(text: "Transcript")
                    Spacer()
                    if let language = meeting.transcript?.language {
                        Text(language)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.dim)
                    }
                    if let recording = meeting.selected, meeting.transcript != nil {
                        RerunButton(title: "Rerun", disabled: meeting.isBusy) {
                            Task {
                                await meeting.transcribe(recording, model: modelId, diarize: diarize, force: true)
                            }
                        }
                    }
                    if let transcript = meeting.transcript {
                        CopyButton(text: { MarkdownExport.transcript(transcript) },
                                   help: "Copy the transcript")
                    }
                }
                transcriptContent
            }
        }
    }

    /// Only transcript-side work is reported here. A summary running is *not*
    /// this card's business: the transcript it is reading stays on screen so it
    /// can be scrolled while the summary is written.
    @ViewBuilder
    private var transcriptContent: some View {
        if let progress = meeting.progress(for: .transcript) {
            JobProgressRow(percent: progress.percent,
                           message: progress.message,
                           onStop: meeting.cancelWork)
                .padding(.vertical, 6)
        } else if let failure = meeting.failure(for: .transcript) {
            VStack(alignment: .leading, spacing: 8) {
                Text(failure)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if let recording = meeting.selected {
                    Button("Try again") {
                        Task { await meeting.transcribe(recording, model: modelId, diarize: diarize) }
                    }
                    .buttonStyle(AccentButtonStyle())
                }
            }
        } else if let transcript = meeting.transcript {
            transcriptList(transcript)
        } else if let recording = meeting.selected {
            VStack(alignment: .leading, spacing: 8) {
                Text("This recording has no transcript yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.dim)
                Button("Transcribe") {
                    Task { await meeting.transcribe(recording, model: modelId, diarize: diarize) }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(meeting.isBusy)
            }
        } else {
            Text("Every line will be tagged with who said it — your microphone track "
                 + "versus the call's audio — so a summary can always be checked against the source.")
                .font(.system(size: 11.5))
                .lineSpacing(2)
                .foregroundStyle(theme.dim)
        }
    }

    private func transcriptList(_ transcript: MeetingTranscript) -> some View {
        // Lazy for the same reason the docked card is: an hour-long call is
        // several hundred rows of wrapped text, and a plain VStack lays out
        // every one of them on every pass to show five.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(transcript.segments) { segment in
                    transcriptRow(segment, speakers: transcript.speakers)
                }
            }
        }
        .frame(maxHeight: 320)
    }

    private func transcriptRow(_ segment: MeetingTranscript.Segment,
                               speakers: [String: String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Timecode(text: Self.clockText(segment.start), seconds: segment.start)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(speakers[segment.speaker] ?? segment.speaker)
                    .font(.system(size: 11))
                    // The far side is the accent colour; my own voice and an
                    // imported file's single speaker stay neutral. Named
                    // participants ("them-2") are the far side too.
                    .foregroundStyle(segment.speaker.hasPrefix("them") ? theme.accent : theme.dim)
                Text(segment.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private static func clockText(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
