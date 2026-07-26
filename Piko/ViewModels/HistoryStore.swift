import Foundation
import Observation

/// One processed artifact. Identity is the source file path — reprocessing
/// the same video updates its entry instead of duplicating it.
struct HistoryEntry: Codable, Identifiable {
    let videoPath: String
    let title: String
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
        let entry = HistoryEntry(
            videoPath: videoURL.path,
            title: videoURL.deletingPathExtension().lastPathComponent,
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
