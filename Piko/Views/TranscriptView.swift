import SwiftUI

/// What a dropped video turns into first: its words, with every free export
/// already available and the burn waiting to be asked for.
///
/// The order is the point. Dropping a file used to spend a full re-encode
/// before showing anything, which meant a misheard name could not be caught
/// until after the expensive part, and could not be fixed at all.
///
/// Built from the same pieces as the meeting transcript — `ThemedCard`,
/// `SectionLabel`, `Timecode`, hairline-separated rows — because it is the
/// same thing on screen and should not read as a second app.
struct TranscriptView: View {
    @Bindable var processor: VideoProcessorVM
    var onBurn: () -> Void
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            transcriptCard
            exportCard
            Spacer(minLength: 0)
        }
    }

    // MARK: - Transcript

    private var transcriptCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    SectionLabel(text: "Transcript")
                    Spacer()
                    if let language = processor.detectedLanguage, language != "unknown" {
                        Text(language)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.dim)
                    }
                    if processor.editedLineCount > 0 {
                        RerunButton(title: "Revert", disabled: false) {
                            processor.revertEdits()
                        }
                    }
                    CopyButton(text: { processor.transcript?.plainText ?? "" },
                               help: "Copy the transcript")
                }
                if let note = editNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                }
                lines
            }
        }
    }

    /// Only shown when there is something to say about the corrections —
    /// how many stand, and whether any lost their place in a re-transcription.
    private var editNote: String? {
        var parts: [String] = []
        if processor.editedLineCount > 0 {
            parts.append("\(processor.editedLineCount) line(s) edited")
        }
        if processor.unplacedEdits > 0 {
            // Kept in the file rather than dropped: one stale correction is
            // recoverable, text a person typed is not.
            parts.append("\(processor.unplacedEdits) could not be placed after re-transcribing")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var lines: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(processor.transcript?.lines ?? []) { line in
                    TranscriptLineRow(line: line) { newText in
                        processor.editLine(id: line.id, to: newText)
                    }
                }
            }
        }
        .frame(maxHeight: 420)
    }

    // MARK: - Exports

    /// Ordered by what each costs the user, cheapest first — the same ladder
    /// the meeting vertical uses for tasks. Everything on the top row is free;
    /// the burn is the one that spends a full re-encode, so it stands alone.
    private var exportCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    SectionLabel(text: "Export")
                    Spacer()
                    Button("Burn Into Video") { onBurn() }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(processor.isProcessing)
                }
                FlowLayout(spacing: 7) {
                    Button("Save Text…") { processor.saveTranscriptText() }
                    if processor.srtURL != nil {
                        Button("Save .srt…") { processor.saveSRT() }
                    }
                    if processor.vttURL != nil {
                        Button("Save .vtt…") { processor.saveVTT() }
                    }
                    if processor.subtitleURL != nil {
                        Button("Save .ass…") { processor.saveASS() }
                    }
                }
                .controlSize(.small)
                Text("Subtitle files cost nothing and are already written. "
                     + "Burning re-encodes the whole video.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dim)
            }
        }
    }
}
