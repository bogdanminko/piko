import AppKit
import Foundation

/// Handing results to the user's own disk.
///
/// Nothing is ever written next to the source video: renders live in the app
/// cache and leave it only through a save panel. The ladder is ordered by
/// what each rung costs — plain text and `.srt` cost nothing and are reachable
/// from the transcript screen; the burned video costs a full re-encode and is
/// reachable only after one.
extension VideoProcessorVM {
    /// Copy the rendered video out of the cache to a user-chosen location.
    func saveVideo() {
        guard let outputURL, let videoURL else { return }
        exportFile(
            from: outputURL,
            suggestedName: videoURL.deletingPathExtension().lastPathComponent + "_subtitled.mp4"
        )
    }

    /// One method per format rather than one "subtitles" button, because the
    /// formats are not interchangeable: `.srt` is what YouTube, Vimeo and
    /// every editor read, `.ass` is the only one that carries the look. The
    /// button that said "Export .srt…" used to hand over an `.ass`.
    func saveSRT() { saveSubtitleFile(srtURL, extension: "srt") }
    func saveVTT() { saveSubtitleFile(vttURL, extension: "vtt") }
    func saveASS() { saveSubtitleFile(subtitleURL, extension: "ass") }

    private func saveSubtitleFile(_ source: URL?, extension ext: String) {
        guard let source, let videoURL else { return }
        exportFile(
            from: source,
            suggestedName: videoURL.deletingPathExtension().lastPathComponent + ".\(ext)"
        )
    }

    /// The corrected transcript as plain text — the one export with no timing
    /// in it at all, for a description, a post or a set of notes.
    func saveTranscriptText() {
        guard let transcript, let videoURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? transcript.plainText.write(to: dest, atomically: true, encoding: .utf8)
    }

    func copyTranscript() {
        guard let transcript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.plainText, forType: .string)
    }

    private func exportFile(from source: URL, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save file"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
