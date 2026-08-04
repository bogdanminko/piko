import SwiftUI

// Work rendered inside the conversation.
//
// These are the reason the workspace does not navigate anywhere when you hand
// it a file. A chat that collects a file and then throws you onto a different
// screen has made the conversation a lobby; keeping the run, the transcript
// and the exports in the thread makes it the workspace. None of them hold
// state — each reads the view model that is actually running, so a card from
// four minutes ago still shows the truth.

// MARK: - The run

/// Progress of the transcription this turn started.
struct ChatJobCard: View {
    @Bindable var processor: VideoProcessorVM
    @Environment(\.pikoTheme) private var theme

    /// The three steps the backend really reports, in the order it reports
    /// them: audio out of the container, the model, then the subtitle files.
    /// Named after what they produce rather than what they run.
    private static let steps = ["Transcribe", "Line up timecodes", "Subtitle files"]

    var body: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 9) {
                    SectionLabel(text: isDone ? "Done" : "Running")
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                    Spacer()
                    Text(percentText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(isDone ? theme.positive : theme.accent)
                }

                HStack(spacing: 7) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, name in
                        if index > 0 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundStyle(theme.dim)
                        }
                        step(name, index: index)
                    }
                }

                // Full when finished. The backend stops reporting wherever it
                // stopped, so a card headed "Done · finished" was being drawn
                // over a bar at five percent — the two halves of one card
                // contradicting each other.
                ProgressView(value: isDone ? 100 : min(max(processor.progressPercent, 0), 100),
                             total: 100)
                    .progressViewStyle(.linear)

                if !isDone {
                    HStack(spacing: 9) {
                        Text(processor.progressMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.dim)
                            .lineLimit(1)
                        Spacer()
                        Button("Cancel") { processor.cancel() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var isDone: Bool {
        if case .processing = processor.state { return false }
        return processor.hasTranscript
    }

    private var subtitle: String {
        guard let total = processor.totalMediaSeconds, total > 0 else {
            return "3 steps · nothing uploaded"
        }
        let done = processor.processedMediaSeconds ?? 0
        return "\(clock(done)) / \(clock(total)) · nothing uploaded"
    }

    private var percentText: String {
        isDone ? "finished" : "\(Int(processor.progressPercent))%"
    }

    /// Which step is running, from the stage the backend named. `subtitles`
    /// is the subtitle-only render that writes .srt/.vtt/.ass, so it is the
    /// last two steps; anything before it is the model.
    private var currentStep: Int {
        guard case .processing(let stage, _, _) = processor.state else {
            return isDone ? Self.steps.count : 0
        }
        return stage == "subtitles" ? 2 : 0
    }

    private func step(_ name: String, index: Int) -> some View {
        let state = index < currentStep ? 1 : (index == currentStep ? 0 : -1)
        let tint = state == 1 ? theme.positive : (state == 0 ? theme.accent : theme.dim)
        return VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(theme.dim)
            Text(name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.text)
                .lineLimit(1)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(state == -1 ? 0.05 : 0.13))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(tint.opacity(state == -1 ? 0 : 0.35))
                }
        }
        .opacity(state == -1 ? 0.6 : 1)
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - The transcript

/// The finished transcript, correctable without leaving the thread.
///
/// Deliberately not titled "lines so far": the ASR reports percentages, not
/// text, so nothing can be shown until it finishes, and a label implying
/// otherwise would be the kind of small lie this screen exists to avoid.
struct ChatTranscriptCard: View {
    @Bindable var processor: VideoProcessorVM
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SectionLabel(text: "Transcript")
                    Text("click any line to correct it")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                    Spacer()
                    if processor.editedLineCount > 0 {
                        Text("\(processor.editedLineCount) edited")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.accent)
                    }
                    CopyButton(text: { processor.transcript?.plainText ?? "" },
                               help: "Copy the transcript")
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(processor.transcript?.lines ?? []) { line in
                            TranscriptLineRow(line: line) { newText in
                                processor.editLine(id: line.id, to: newText)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }
}

// MARK: - What comes out

/// The export ladder, in the thread, cheapest first.
struct ChatExportsCard: View {
    @Bindable var processor: VideoProcessorVM
    var onBurn: () -> Void
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    SectionLabel(text: "Save")
                    Text("subtitle files are already written")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                    Spacer()
                    Button("Style & burn in…") { onBurn() }
                        .buttonStyle(AccentButtonStyle())
                        .controlSize(.small)
                }
                FlowLayout(spacing: 7) {
                    Button("Text") { processor.saveTranscriptText() }
                    if processor.srtURL != nil {
                        Button(".srt") { processor.saveSRT() }
                    }
                    if processor.vttURL != nil {
                        Button(".vtt") { processor.saveVTT() }
                    }
                    if processor.subtitleURL != nil {
                        Button(".ass") { processor.saveASS() }
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - A call

/// A call's transcript, with the side that said each line.
///
/// The same rows the meeting screen draws — timecode, speaker, text — because
/// it is the same thing, and the panel is where it now lives.
struct ChatMeetingTranscriptCard: View {
    @Bindable var meeting: MeetingVM
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    SectionLabel(text: "Transcript")
                    if let transcript = meeting.transcript {
                        Text("\(transcript.segments.count) lines · each linked to its second")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.dim)
                    }
                    Spacer()
                    if let transcript = meeting.transcript {
                        CopyButton(text: { MarkdownExport.transcript(transcript) },
                                   help: "Copy the transcript")
                    }
                }

                if let transcript = meeting.transcript {
                    // Lazy, and not as an optimisation: a plain VStack lays out
                    // every one of a long call's segments — four hundred rows of
                    // wrapped text — on each pass, while five are on screen.
                    // That is the whole of the scroll jank, and it is why an
                    // idle CPU and a stuttering list were the same picture.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(transcript.segments) { segment in
                                row(segment, speakers: transcript.speakers)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func row(_ segment: MeetingTranscript.Segment,
                     speakers: [String: String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Timecode(text: clock(segment.start), seconds: segment.start)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(speakers[segment.speaker] ?? segment.speaker)
                    .font(.system(size: 11))
                    // The far side is the accent colour; my own voice stays neutral.
                    .foregroundStyle(segment.speaker.hasPrefix("them") ? theme.accent : theme.dim)
                Text(segment.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
