import CryptoKit
import Foundation

/// A cached transcription, read for display and for composing a corrected
/// copy on the way to a render.
///
/// Deliberately not the thing the user edits. Corrections live beside it in
/// `CaptionEdits`, and the two are composed on the way out — the same
/// arrangement as the meeting vertical's `SummaryEdits` / `ComposedSummary`,
/// for the same reason: re-running the model must never be able to destroy
/// something a person typed. The cache file stays strictly derived, so
/// `force` re-transcribing is always safe.
struct CaptionTranscript {
    /// One readable row: the ASR's own segment, which is also the unit a
    /// person corrects. Word-level editing would be the true grain, but
    /// nobody wants to click a word to fix a name — they retype the line.
    struct Line: Identifiable, Equatable {
        let id: Int
        let start: Double
        let end: Double
        /// What the model said. Kept even when overridden: it is the anchor
        /// that re-places an edit after a re-transcription.
        let generated: String
        var text: String

        var isEdited: Bool { text != generated }
    }

    var language: String?
    var lines: [Line]

    var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// A fingerprint of the corrected text that survives app restarts.
    ///
    /// `hashValue` would not: Swift seeds string hashing per process, so a
    /// render keyed on it could never be found again in a later session and
    /// every edited video would re-encode on every launch.
    var textFingerprint: String {
        let digest = SHA256.hash(data: Data(plainText.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(10).description
    }

    // MARK: - Reading

    /// Read the backend's transcription JSON and fold it into display lines.
    static func load(from url: URL, applying edits: CaptionEdits = .empty) throws -> CaptionTranscript {
        let raw = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
        let segments = root["segments"] as? [[String: Any]] ?? []

        var lines: [Line] = []
        for (index, segment) in segments.enumerated() {
            guard let line = Self.line(from: segment, index: index) else { continue }
            lines.append(line)
        }

        var transcript = CaptionTranscript(language: root["language"] as? String, lines: lines)
        transcript.apply(edits)
        return transcript
    }

    private static func line(from segment: [String: Any], index: Int) -> Line? {
        let words = segment["words"] as? [[String: Any]] ?? []
        let text: String
        let start: Double
        let end: Double

        if words.isEmpty {
            // Not every ASR pass returns per-word timing; such a segment is
            // still a perfectly good line, just a coarser one.
            text = (segment["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            start = segment["start"] as? Double ?? 0
            end = segment["end"] as? Double ?? start
        } else {
            text = words
                .compactMap { $0["word"] as? String }
                .joined()
                .trimmingCharacters(in: .whitespaces)
            start = words.first?["start"] as? Double ?? 0
            end = words.last?["end"] as? Double ?? start
        }

        guard !text.isEmpty else { return nil }
        return Line(id: index, start: start, end: end, generated: text, text: text)
    }

    // MARK: - Composition

    /// Overlay stored corrections onto the generated lines.
    mutating func apply(_ edits: CaptionEdits) {
        for edit in edits.edits {
            guard let index = edits.index(of: edit, in: lines) else { continue }
            lines[index].text = edit.newText
        }
    }

    /// Every line whose text a person has changed, as storable edits.
    var currentEdits: [CaptionEdit] {
        lines.filter(\.isEdited).map {
            CaptionEdit(anchorStart: $0.start, originalText: $0.generated, newText: $0.text)
        }
    }
}

// MARK: - Writing a corrected transcription for the renderer

/// Writes the composition of a cached transcription and the user's edits.
///
/// The backend re-reads `transcription_path` on every render, so a corrected
/// copy is all it takes to make a fix reach the picture — no protocol change,
/// and the original cache entry is never touched.
enum CaptionTranscriptComposer {
    /// Compose `source` with `edits` into `destination`.
    ///
    /// Returns the path the renderer should use: `source` itself when there
    /// is nothing to correct, so an unedited transcript costs nothing.
    static func compose(source: URL, edits: [CaptionEdit], destination: URL) throws -> URL {
        guard !edits.isEmpty else { return source }

        let raw = try Data(contentsOf: source)
        guard var root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              var segments = root["segments"] as? [[String: Any]] else {
            return source
        }

        let lines = try CaptionTranscript.load(from: source).lines
        let store = CaptionEdits(edits: edits)

        for edit in edits {
            guard let index = store.index(of: edit, in: lines) else { continue }
            // `index` positions the line; the segment it came from is its id.
            // Empty segments are dropped when lines are built, so the two
            // drift apart the moment a transcript contains one.
            let segmentIndex = lines[index].id
            guard segmentIndex < segments.count else { continue }
            segments[segmentIndex] = rewrite(
                segment: segments[segmentIndex], to: edit.newText, line: lines[index]
            )
        }

        root["segments"] = segments
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: root).write(to: destination)
        return destination
    }

    /// Put corrected text back on the original timings.
    ///
    /// Same word count is the ordinary case — a name fixed, a brand spelled
    /// right — and there every other key the backend wrote (probability, which
    /// keyword detection reads) survives untouched. A rewritten line of a
    /// different length cannot keep them, so its words are re-timed across the
    /// line's own span instead of inventing timings from nowhere.
    private static func rewrite(
        segment: [String: Any], to newText: String, line: CaptionTranscript.Line
    ) -> [String: Any] {
        var segment = segment
        let replacements = newText.split(separator: " ").map(String.init)
        segment["text"] = newText

        guard var words = segment["words"] as? [[String: Any]], !words.isEmpty else {
            return segment
        }

        if replacements.count == words.count {
            for (index, replacement) in replacements.enumerated() {
                // Whisper words carry a leading space; keeping it keeps the
                // joined line from losing its word breaks.
                let lead = (words[index]["word"] as? String)?.hasPrefix(" ") == true ? " " : ""
                words[index]["word"] = lead + replacement
            }
            segment["words"] = words
            return segment
        }

        segment["words"] = retime(replacements, from: line.start, to: line.end)
        return segment
    }

    /// Spread words across a span, proportionally to how long they are.
    private static func retime(_ words: [String], from start: Double, to end: Double) -> [[String: Any]] {
        guard !words.isEmpty else { return [] }
        let span = max(end - start, 0.001)
        let total = Double(words.reduce(0) { $0 + max($1.count, 1) })

        var cursor = start
        return words.enumerated().map { index, word in
            let share = span * Double(max(word.count, 1)) / total
            let wordStart = cursor
            cursor = index == words.count - 1 ? end : cursor + share
            return ["word": (index == 0 ? "" : " ") + word, "start": wordStart, "end": cursor]
        }
    }
}
