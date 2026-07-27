import SwiftUI
import UniformTypeIdentifiers

/// Meeting Summary screen. Recording and transcription are real: the recorder
/// writes a microphone track and a system-audio track, and the backend turns
/// them into a transcript where every line knows which side said it. The
/// summary cards on the left are still a design preview.
struct MeetingSummaryView: View {
    @Bindable var meeting: MeetingVM
    /// Whisper/Parakeet model chosen on the Models screen.
    let modelId: String
    /// Whether to tell the far-end voices apart — the Speakers switch on the
    /// Models screen, already checked against the model being on disk.
    let diarize: Bool
    /// Tier, sampling and summary language picked on the Models screen.
    @Bindable var summarizer: SummarizerVM

    private var summarizerParams: [String: Any] { summarizer.requestParams }

    @Environment(\.pikoTheme) private var theme
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    /// The recording whose name is being edited, if any — the rows are built by
    /// a function, so the one editing state lives here rather than in each row.
    @State private var renamingID: String?

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
                VStack(spacing: 12) {
                    recordingsCard
                    transcriptCard
                }
                .frame(width: 380)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
        .onAppear { meeting.refresh() }
        .fileImporter(
            isPresented: $isImporterPresented,
            // .data keeps the panel open to anything: the real compatibility
            // list is whatever ffmpeg can decode, not what macOS has a UTType for.
            allowedContentTypes: [.audiovisualContent, .audio, .movie, .data]
        ) { result in
            if case .success(let url) = result {
                importFile(url)
            }
        }
    }

    private func importFile(_ url: URL) {
        Task { await meeting.importFile(at: url, model: modelId, diarize: diarize) }
    }

    /// The only export control on the screen: one button, with Copy behind a
    /// long-press menu rather than a second button competing with it.
    private var header: some View {
        ScreenHeader(title: "Meeting Summary",
                     subtitle: "Record a call, get a summary you can verify") {
            Button("Export Markdown") { exportMarkdown(save: true) }
                .buttonStyle(AccentButtonStyle())
                .disabled(meeting.composed?.isEmpty ?? true)
                .contextMenu {
                    Button("Copy as Markdown") { exportMarkdown(save: false) }
                }
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

    // MARK: - Recordings

    private var recordingsCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    SectionLabel(text: "Recordings")
                    Spacer()
                    Text("\(meeting.recordings.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                }
                if meeting.recordings.isEmpty {
                    Text("Nothing recorded yet. Press record before the call starts — "
                         + "you and the other side are captured as separate tracks.")
                        .font(.system(size: 11.5))
                        .lineSpacing(2)
                        .foregroundStyle(theme.dim)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(meeting.recordings) { recording in
                                recordingRow(recording)
                            }
                        }
                    }
                    .frame(maxHeight: 132)
                }
                dropZone
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !meeting.isBusy, !meeting.recorder.isActive else {
                return false
            }
            importFile(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    /// Drop target for existing files. Deliberately a full-width zone rather
    /// than an icon button: dragging a call recording in is the common way to
    /// use this, and clicking it still opens the file panel.
    private var dropZone: some View {
        let canImport = !meeting.isBusy && !meeting.recorder.isActive
        return VStack(spacing: 4) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(isDropTargeted ? theme.accent : theme.dim)
            Text(isDropTargeted ? "Drop to transcribe" : "Drop an audio or video file")
                .font(.system(size: 11.5))
                .foregroundStyle(isDropTargeted ? theme.accent : theme.text)
            Text("or click to choose one")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, meeting.recordings.isEmpty ? 20 : 13)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDropTargeted ? theme.accent.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted ? theme.accent : theme.line,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .contentShape(Rectangle())
        .opacity(canImport ? 1 : 0.5)
        .onTapGesture {
            guard canImport else { return }
            isImporterPresented = true
        }
    }

    private func recordingRow(_ recording: MeetingRecording) -> some View {
        let isSelected = meeting.selectedID == recording.id
        return HStack(spacing: 8) {
            Image(systemName: hasTranscript(recording) ? "text.alignleft" : "waveform")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? theme.accent : theme.dim)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                EditableTitle(
                    text: recording.title,
                    isEditing: Binding(get: { renamingID == recording.id },
                                       set: { renamingID = $0 ? recording.id : nil }),
                    font: .system(size: 12.5),
                    onRename: { meeting.rename(recording, to: $0) }
                )
                Text(sourcesText(recording))
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.dim)
            }
            Spacer(minLength: 6)
            Timecode(text: Self.clockText(recording.duration))
            Button {
                meeting.delete(recording)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.dim)
            }
            .buttonStyle(.plain)
            .help("Delete recording")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background(isSelected ? theme.card2 : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            guard renamingID != recording.id else { return }
            meeting.select(recording)
        }
    }

    private func hasTranscript(_ recording: MeetingRecording) -> Bool {
        MeetingLibrary.hasTranscript(id: recording.id)
    }

    private func sourcesText(_ recording: MeetingRecording) -> String {
        if let source = recording.sourceFile {
            return "imported · \(URL(fileURLWithPath: source).lastPathComponent)"
        }
        var parts: [String] = []
        if let mic = recording.micTrack { parts.append(mic.device) }
        if recording.systemTrack != nil { parts.append("system audio") }
        return parts.isEmpty ? "no tracks" : parts.joined(separator: " · ")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
            Timecode(text: Self.clockText(segment.start))
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
