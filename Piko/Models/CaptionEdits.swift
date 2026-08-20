import CryptoKit
import Foundation

/// One corrected line, and enough context to find that line again.
///
/// `originalText` is not decoration: it is half the anchor. A transcript can
/// be regenerated with a different model, at which point line 7 is no longer
/// the same sentence, and a stored index would silently rewrite the wrong one.
struct CaptionEdit: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var anchorStart: Double
    var originalText: String
    var newText: String

    enum CodingKeys: String, CodingKey {
        case id, anchorStart, originalText, newText
    }
}

/// The corrections a person made to one video's captions.
///
/// Stored in Application Support rather than Caches — this is typed by hand,
/// so "Clear Cache" must not be able to take it. Keyed on the source video,
/// not on the transcription file, so re-transcribing with another model still
/// finds the same corrections.
struct CaptionEdits: Codable, Equatable {
    static let empty = CaptionEdits(edits: [])

    /// How far an edit may drift from where it was made and still be
    /// recognised as the same line. Caption lines are seconds long, so this
    /// is far tighter than the meeting summary's fifteen.
    static let anchorWindow: Double = 3.0
    /// How much of the original wording must survive for a re-transcribed
    /// line to count as the same line.
    static let minimumWordOverlap: Double = 0.5

    var version: Int = 1
    var edits: [CaptionEdit]

    // MARK: - Anchoring

    /// Index of the line this edit belongs to, or nil if it no longer fits
    /// anywhere — in which case it stays in the file, unapplied, rather than
    /// being thrown away.
    func index(of edit: CaptionEdit, in lines: [CaptionTranscript.Line]) -> Int? {
        var best: (index: Int, distance: Double)?

        for (index, line) in lines.enumerated() {
            let distance = abs(line.start - edit.anchorStart)
            guard distance <= Self.anchorWindow else { continue }
            guard Self.overlap(line.generated, edit.originalText) >= Self.minimumWordOverlap else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// Edits that no longer match any line. Shown as a count rather than
    /// dropped: one stale correction is recoverable, deleted text is not.
    func unplaced(in lines: [CaptionTranscript.Line]) -> [CaptionEdit] {
        edits.filter { index(of: $0, in: lines) == nil }
    }

    private static func overlap(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(lhs.lowercased().split(separator: " "))
        let right = Set(rhs.lowercased().split(separator: " "))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(min(left.count, right.count))
    }

    // MARK: - Storage

    static let root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Piko/CaptionEdits", isDirectory: true)

    /// Stable per-video file name. The path is hashed rather than escaped so
    /// a long or oddly punctuated path cannot produce an illegal file name.
    static func url(forVideoAt path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(24)
        return root.appendingPathComponent("\(name).json")
    }

    static func load(forVideoAt path: String) -> CaptionEdits {
        guard let data = try? Data(contentsOf: url(forVideoAt: path)),
              let stored = try? JSONDecoder().decode(CaptionEdits.self, from: data) else {
            return .empty
        }
        return stored
    }

    /// Write, or remove the file entirely once the last edit is undone —
    /// an empty overlay and no overlay must not be different states.
    func save(forVideoAt path: String) {
        let destination = Self.url(forVideoAt: path)
        guard !edits.isEmpty else {
            try? FileManager.default.removeItem(at: destination)
            return
        }
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: destination)
    }
}
