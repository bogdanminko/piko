import Foundation

/// The notes a person takes during a call, and where they go.
///
/// Deliberately not an overlay (unlike `SummaryEdits`): nothing generates a
/// note, so there is no generated version to compose against and no rerun that
/// could destroy one. Every change writes straight through to `notes.json` in
/// the meeting folder — a call being recorded is exactly the situation where
/// "save it at the end" loses everything.
extension MeetingVM {
    /// Which meeting a note typed *now* belongs to: the one being recorded if
    /// there is one, otherwise whatever is open. The recorder wins because the
    /// list can still be showing last week's call at the moment Record is hit.
    var notesID: String? {
        recorder.activeID ?? selectedID
    }

    /// The timecode a note typed now would carry — the recorder's clock, which
    /// stops on pause exactly as the audio does, so the two never drift.
    /// Nil when nothing is recording: a note added afterwards has no moment,
    /// and guessing one would put a citation where there is no evidence.
    var noteSeconds: Double? {
        recorder.isActive ? recorder.elapsed : nil
    }

    var canTakeNotes: Bool { notesID != nil }

    func addNote(_ text: String) {
        mutateNotes { $0.add(text, at: noteSeconds) }
    }

    func updateNote(_ note: MeetingNote, to text: String) {
        mutateNotes { $0.update(note.id, text: text) }
    }

    func deleteNote(_ note: MeetingNote) {
        mutateNotes { $0.remove(note.id) }
    }

    /// Notes taken since the summary on disk was written — the ones it cannot
    /// possibly have read. The screen offers a rerun on the strength of this
    /// rather than rerunning by itself: a summary costs minutes of the model's
    /// time, and the person who just typed a line is the one who knows whether
    /// it changes the answer.
    var notesMissingFromSummary: [MeetingNote] {
        guard summary != nil, let id = selectedID,
              let written = MeetingLibrary.summaryWritten(for: id) else { return [] }
        return notes.written(after: written)
    }

    /// Point the notes at whichever meeting they now belong to, reloading from
    /// disk when that changes. Cheap enough to call on every pass; the file is
    /// read only when the id actually moves.
    func syncNotes() {
        guard loadedNotesID != notesID else { return }
        loadedNotesID = notesID
        notes = notesID.map(MeetingLibrary.loadNotes) ?? MeetingNotes()
    }

    private func mutateNotes(_ change: (inout MeetingNotes) -> Void) {
        syncNotes()
        guard let id = notesID else { return }
        change(&notes)
        try? MeetingLibrary.saveNotes(notes, for: id)
    }
}
