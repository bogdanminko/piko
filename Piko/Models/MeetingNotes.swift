import Foundation

/// One line the user typed while a call was being recorded.
///
/// Not a correction of anything, which is what makes this the one piece of
/// meeting text that is *not* an overlay: nothing generates a note, so there is
/// no generated version for it to compose against and nothing a rerun could
/// overwrite. It is simply stored, in its own file in the meeting folder.
struct MeetingNote: Codable, Identifiable, Equatable {
    var id: String
    /// Seconds from the start of the recording — the same axis the transcript
    /// and the player use, because it is stamped from the recorder's own clock
    /// (which stops on pause, exactly as the audio does).
    ///
    /// Nil when there was no clock running: an imported file, or a line added
    /// after the call. Such a note is still worth keeping — it just cannot be
    /// a citation, and the backend anchors only the ones that can.
    var at: Double?
    var text: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, at, text
        case createdAt = "created_at"
    }

    init(id: String = UUID().uuidString, at: Double?, text: String, createdAt: Date = Date()) {
        self.id = id
        self.at = at
        self.text = text
        self.createdAt = createdAt
    }
}

/// `notes.json` in the meeting folder: what a person wrote down during a call.
///
/// Application Support beside the audio, never Caches — it is typed text, and
/// "Clear Cache" must not be able to reach it. Written by the app the moment a
/// line is entered, so a crash mid-call costs the notes no more than it costs
/// the recording; read by the backend on `summarize_meeting` and never written
/// by it.
struct MeetingNotes: Codable, Equatable {
    var version = 1
    var notes: [MeetingNote] = []

    var isEmpty: Bool { notes.isEmpty }
    var count: Int { notes.count }

    /// Timed lines in the order they were spoken, untimed ones last in the
    /// order they were written. The list is the reading order everywhere it
    /// appears, so it is kept sorted here rather than at each call site.
    private mutating func sort() {
        notes.sort { left, right in
            switch (left.at, right.at) {
            case let (lhs?, rhs?): return lhs == rhs ? left.createdAt < right.createdAt : lhs < rhs
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return left.createdAt < right.createdAt
            }
        }
    }

    /// Adds a line, or does nothing if it is blank. Returns the note so a view
    /// can scroll to it.
    @discardableResult
    mutating func add(_ text: String, at seconds: Double?) -> MeetingNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let note = MeetingNote(at: seconds, text: trimmed)
        notes.append(note)
        sort()
        return note
    }

    /// Retyping a line changes its text and nothing else: the timecode is when
    /// it was written, not when it was corrected.
    mutating func update(_ id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if trimmed.isEmpty {
            notes.remove(at: index)
        } else {
            notes[index].text = trimmed
        }
    }

    mutating func remove(_ id: String) {
        notes.removeAll { $0.id == id }
    }

    /// Notes written after this moment — how the summary screen knows it is
    /// reading an answer that never saw them.
    func written(after moment: Date) -> [MeetingNote] {
        notes.filter { $0.createdAt > moment }
    }
}

// MARK: - Reading a transcript with the notes in it

/// A transcript and its notes on one axis.
///
/// The notes exist because somebody marked a moment, so the moment is where
/// they belong: woven into the lines rather than filed in a list beside them.
/// Untimed notes are absent here on purpose — they have no place on the axis,
/// and inventing one for them is the same lie as an invented timecode. They
/// stay visible in the notes card, which is not sorted by anything.
enum TranscriptEntry: Identifiable {
    case line(MeetingTranscript.Segment)
    case note(MeetingNote)

    var id: String {
        switch self {
        case .line(let segment): return "line-\(segment.id)"
        case .note(let note): return "note-\(note.id)"
        }
    }

    var start: Double {
        switch self {
        case .line(let segment): return segment.start
        case .note(let note): return note.at ?? 0
        }
    }

    /// A note sits *after* the line that was being spoken when it was typed —
    /// the same anchoring the backend uses, and for the same reason: a note is
    /// written about what was just said.
    static func merge(_ transcript: MeetingTranscript, notes: [MeetingNote]) -> [TranscriptEntry] {
        let timed = notes.filter { $0.at != nil }
        guard !timed.isEmpty else { return transcript.segments.map(TranscriptEntry.line) }
        let entries = transcript.segments.map(TranscriptEntry.line) + timed.map(TranscriptEntry.note)
        return entries.enumerated().sorted { left, right in
            if left.element.start != right.element.start {
                return left.element.start < right.element.start
            }
            // Equal seconds: the line first, then the note about it. Stable
            // beyond that, so two notes on one second keep their own order.
            let ranks = (left.element.sortRank, right.element.sortRank)
            return ranks.0 == ranks.1 ? left.offset < right.offset : ranks.0 < ranks.1
        }
        .map(\.element)
    }

    private var sortRank: Int {
        switch self {
        case .line: return 0
        case .note: return 1
        }
    }
}
