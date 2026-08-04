import Foundation

/// Reading the words and correcting them.
///
/// The cached transcription stays exactly as the model wrote it. Corrections
/// are stored separately, per source video, and composed into a copy on the
/// way to a render — the same arrangement the meeting vertical uses for
/// summary edits, and for the same reason: re-running the model must never be
/// able to destroy something a person typed.
extension VideoProcessorVM {
    /// Read the cached transcription and overlay the stored corrections.
    func loadTranscript() {
        guard let transcriptionPath, let videoURL else { return }
        edits = CaptionEdits.load(forVideoAt: videoURL.path)

        let url = URL(fileURLWithPath: transcriptionPath)
        guard let loaded = try? CaptionTranscript.load(from: url, applying: edits) else { return }
        transcript = loaded
        unplacedEdits = edits.unplaced(in: loaded.lines).count
    }

    /// Correct one line. Typing back exactly what the model said drops the
    /// override rather than storing a copy of it, so the line stops reading as
    /// edited — the same rule as the meeting summary's field overrides. An
    /// emptied field is a cancel, not a deletion: a caption line with no text
    /// is a hole in the picture, which is never what was meant.
    func editLine(id: Int, to newText: String) {
        guard var transcript, let videoURL,
              let index = transcript.lines.firstIndex(where: { $0.id == id }) else { return }

        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.lines[index].text = trimmed.isEmpty ? transcript.lines[index].generated : trimmed
        self.transcript = transcript

        edits = CaptionEdits(edits: transcript.currentEdits)
        edits.save(forVideoAt: videoURL.path)
    }

    func revertEdits() {
        guard var transcript, let videoURL else { return }
        for index in transcript.lines.indices {
            transcript.lines[index].text = transcript.lines[index].generated
        }
        self.transcript = transcript
        edits = .empty
        edits.save(forVideoAt: videoURL.path)
        unplacedEdits = 0
    }

    var editedLineCount: Int {
        transcript?.lines.filter(\.isEdited).count ?? 0
    }

    /// The transcription the renderer should read: the cached one when
    /// nothing was corrected, a composed copy when something was.
    func transcriptionPathForRender() -> String? {
        guard let transcriptionPath else { return nil }
        let source = URL(fileURLWithPath: transcriptionPath)
        guard !edits.edits.isEmpty else { return transcriptionPath }

        let destination = source.deletingPathExtension().appendingPathExtension("edited.json")
        let composed = try? CaptionTranscriptComposer.compose(
            source: source, edits: edits.edits, destination: destination
        )
        return (composed ?? source).path
    }
}
