import Foundation
import Observation

/// One processed artifact. Identity is the source file path — reprocessing
/// the same video updates its entry instead of duplicating it.
struct HistoryEntry: Codable, Identifiable {
    let videoPath: String
    /// Starts as the file's name and stays editable from the Library — see
    /// `rename`. Reprocessing the same video keeps whatever it says.
    var title: String
    let kind: String
    var style: String
    var language: String?
    var wordCount: Int
    var date: Date

    var id: String { videoPath }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: videoPath)
    }
}

/// Persistent processing history (the "sessions" behind Recent and the
/// Library table). Stored as JSON in Application Support.
@MainActor
@Observable
final class HistoryStore {
    private static let maxEntries = 50

    private static let fileURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Piko/history.json")

    private(set) var entries: [HistoryEntry] = []

    init() {
        load()
    }

    /// Record a completed captions run. Newest first, deduplicated by path.
    func record(videoURL: URL, style: String, language: String?, wordCount: Int) {
        let ext = videoURL.pathExtension.uppercased()
        // A rerun updates the run, not the name: re-deriving the title from the
        // file would silently drop a rename the person typed.
        let existing = entries.first { $0.videoPath == videoURL.path }
        let entry = HistoryEntry(
            videoPath: videoURL.path,
            title: existing?.title ?? videoURL.deletingPathExtension().lastPathComponent,
            kind: ext.isEmpty ? "Video" : "Video · \(ext)",
            style: style,
            language: language,
            wordCount: wordCount,
            date: Date()
        )
        entries.removeAll { $0.videoPath == entry.videoPath }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Rename an artifact. The video file itself is the user's own and is never
    /// touched — only the name this run is listed under.
    func rename(_ entry: HistoryEntry, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = entries.firstIndex(where: { $0.id == entry.id }),
              entries[index].title != name else { return }
        entries[index].title = name
        save()
    }

    /// Remove a single artifact from history (Library table / sidebar Recent).
    /// Does not touch the source video file, only the recorded entry.
    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        entries = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: Self.fileURL)
        }
    }
}
