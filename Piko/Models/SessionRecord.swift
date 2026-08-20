import Foundation

/// A conversation on disk.
///
/// One file per session — `Application Support/Piko/Sessions/<id>.json` — and
/// not one file holding all of them. The write pattern is what decides this: a
/// thread is appended to constantly, so a single document would be rewritten
/// whole on every landing token, and a crash mid-write would take every chat
/// with it rather than the one being typed into. Per-file is also the shape the
/// rest of the app already has (a folder per recording), so nothing new has to
/// be learned to find one in Finder.
///
/// **It stores the conversation, not the work.** Every artifact a session
/// points at is already on disk and derived from its own source of truth — the
/// recording's folder, the transcription cache, `history.json`. Copying a
/// transcript in here would create a second copy that can disagree with the
/// first, which is the failure this whole codebase keeps arranging itself to
/// avoid. So a restored session carries the *path* and re-derives; the ASR
/// cache makes that a second, not a re-transcription.
struct SessionRecord: Codable {
    var id: UUID
    var title: String
    var isNamed: Bool
    var startedAt: Date
    /// The recording this conversation is about, if it is about one.
    var meetingID: String?
    /// The video it is about, if it is about one. A path rather than a copy.
    var videoPath: String?
    /// Where the reader was, so coming back comes back to it.
    var openArtifact: String?
    var isPanelExpanded: Bool
    var turns: [ChatTurn]
}

/// Reading and writing them. Deliberately free of any view model, so a bad file
/// can be reasoned about — and tested — without an app around it.
enum SessionArchive {
    static let directory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Piko/Sessions")

    static func file(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Everything on disk, newest first. A file that will not decode is skipped
    /// rather than thrown: one unreadable conversation must not cost the user
    /// all the others, and there is nothing here worth halting a launch for.
    static func loadAll() -> [SessionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SessionRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SessionRecord.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func save(_ record: SessionRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        // Atomic: a half-written file is a conversation that decodes to
        // nonsense, and the next launch would drop it on the floor.
        try? data.write(to: file(for: record.id), options: .atomic)
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }

    /// Turns worth keeping.
    ///
    /// A payload is a pointer at live work, not data. `.job` and `.burning`
    /// mark a run that was happening; restoring them draws a progress bar for
    /// something that finished — or was killed — three days ago. Everything
    /// else reads a view model and comes back correct or comes back empty,
    /// which is honest either way.
    static func persistable(_ turns: [ChatTurn]) -> [ChatTurn] {
        turns
            .filter { $0.payload != .job && $0.payload != .burning }
            .map { turn in
                var copy = turn
                // Nothing is mid-stream once the app is gone.
                copy.isStreaming = false
                return copy
            }
    }
}
