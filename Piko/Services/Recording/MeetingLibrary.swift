import Foundation

/// Where recorded meetings live on disk and how they are enumerated.
///
/// Application Support, not Caches: a recording is the user's own material —
/// "Clear Cache" wipes transcripts and renders, never the audio itself.
/// One folder per meeting: `mic.pcm`, `system.pcm`, `meta.json`, and after
/// finalizing `meeting.m4a` / `transcript.json`.
enum MeetingLibrary {
    static let root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Piko/Recordings", isDirectory: true)

    static func folder(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    /// Folder name for a new meeting — sortable and unique per second.
    static func newID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    /// "Jul 26, 2026 at 6:01 PM" — used in recording titles.
    static func timestampTitle(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func createFolder(id: String) throws -> URL {
        let url = folder(for: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func metaURL(for id: String) -> URL {
        folder(for: id).appendingPathComponent("meta.json")
    }

    static func summaryURL(for id: String) -> URL {
        folder(for: id).appendingPathComponent("summary.json")
    }

    static func loadSummary(for recording: MeetingRecording) -> MeetingSummary? {
        guard let data = try? Data(contentsOf: summaryURL(for: recording.id)) else { return nil }
        return try? JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    /// The user's side of a summary — corrections, ticks, exports. Written by
    /// the app only; the backend never reads or overwrites it.
    static func editsURL(for id: String) -> URL {
        folder(for: id).appendingPathComponent("summary.edits.json")
    }

    static func loadEdits(for recording: MeetingRecording) -> SummaryEdits {
        guard let data = try? Data(contentsOf: editsURL(for: recording.id)) else {
            return SummaryEdits()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SummaryEdits.self, from: data)) ?? SummaryEdits()
    }

    /// Atomic, and self-cleaning: an overlay with nothing left in it is removed
    /// rather than left behind as an empty file.
    static func saveEdits(_ edits: SummaryEdits, for id: String) throws {
        let url = editsURL(for: id)
        guard !edits.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(edits).write(to: url, options: .atomic)
    }

    /// What the user typed during the call. Written by the app as each line is
    /// entered; the backend only ever reads it.
    static func notesURL(for id: String) -> URL {
        folder(for: id).appendingPathComponent("notes.json")
    }

    static func loadNotes(for id: String) -> MeetingNotes {
        guard let data = try? Data(contentsOf: notesURL(for: id)) else { return MeetingNotes() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(MeetingNotes.self, from: data)) ?? MeetingNotes()
    }

    /// Atomic, and self-cleaning like the summary overlay: deleting the last
    /// note leaves no file behind for the backend to read as an empty list.
    static func saveNotes(_ notes: MeetingNotes, for id: String) throws {
        let url = notesURL(for: id)
        guard !notes.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(notes).write(to: url, options: .atomic)
    }

    /// When the summary on disk was written, so the screen can tell whether it
    /// was written before the notes it is missing.
    static func summaryWritten(for id: String) -> Date? {
        try? summaryURL(for: id).resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    static func transcriptURL(for id: String) -> URL {
        folder(for: id).appendingPathComponent("transcript.json")
    }

    /// How far a meeting got, asked of the disk rather than of any cached
    /// state — the Library badge and the transcript card both read it.
    static func hasTranscript(id: String) -> Bool {
        FileManager.default.fileExists(atPath: transcriptURL(for: id).path)
    }

    static func hasSummary(id: String) -> Bool {
        FileManager.default.fileExists(atPath: summaryURL(for: id).path)
    }

    /// Playable mix, written by the backend's `finalize_recording`.
    static func mixedAudioURL(for recording: MeetingRecording) -> URL? {
        guard let file = recording.mixedFile else { return nil }
        let url = folder(for: recording.id).appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func save(_ recording: MeetingRecording) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(recording).write(to: metaURL(for: recording.id), options: .atomic)
    }

    static func load(id: String) -> MeetingRecording? {
        guard let data = try? Data(contentsOf: metaURL(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingRecording.self, from: data)
    }

    /// Newest first. Folders without a readable meta.json are ignored — a
    /// recording that crashed before its first save is not a recording.
    static func list() -> [MeetingRecording] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .compactMap { load(id: $0.lastPathComponent) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func loadTranscript(for recording: MeetingRecording) -> MeetingTranscript? {
        guard let data = try? Data(contentsOf: transcriptURL(for: recording.id)) else { return nil }
        return try? JSONDecoder().decode(MeetingTranscript.self, from: data)
    }

    static func delete(_ recording: MeetingRecording) {
        try? FileManager.default.removeItem(at: folder(for: recording.id))
    }

    /// Bytes on disk for one meeting, for the UI's size column.
    static func sizeOnDisk(_ recording: MeetingRecording) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder(for: recording.id), includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
    }
}
