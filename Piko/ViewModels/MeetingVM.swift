import Foundation
import Observation

/// Meeting Summary screen state: recording, the library of recordings, and the
/// transcription that turns one into a speaker-labelled transcript.
///
/// The pipeline stops at the transcript on purpose — summarization is the next
/// step and reads `transcript.json` from the same folder.
@MainActor
@Observable
final class MeetingVM {
    /// Which part of the pipeline a run belongs to.
    ///
    /// Progress and failures are rendered next to the thing being worked on, so
    /// the phase has to say *what* is running: a summary reporting under the
    /// transcript card reads as "I pressed Summarize and transcription started".
    /// Importing is transcript-side — it ends by transcribing what it imported.
    enum Job: Equatable {
        case transcript
        case summary
    }

    enum Phase: Equatable {
        case idle
        case working(job: Job, percent: Double, message: String)
        case failed(job: Job, message: String)
    }

    let permissions: RecordingPermissions
    let recorder: MeetingRecorder

    private(set) var recordings: [MeetingRecording] = []
    private(set) var selectedID: String?
    private(set) var transcript: MeetingTranscript?
    private(set) var summary: MeetingSummary?
    /// The user's corrections and task state for the selected meeting. Kept in
    /// its own file so a rerun of the summary can never overwrite them.
    /// Mutated only through the methods in MeetingVM+Edits.swift.
    var edits = SummaryEdits()
    /// What the user typed during the call. Not an overlay — nothing generates
    /// a note — so it is stored as it is written; see MeetingVM+Notes.swift.
    var notes = MeetingNotes()
    /// Which meeting `notes` was last read for, so switching between a live
    /// recording and an open one reloads rather than writing one's lines into
    /// the other's file.
    var loadedNotesID: String?
    private(set) var phase: Phase = .idle

    /// What the screen shows: the generated summary with the overlay applied.
    var composed: ComposedSummary? {
        summary.map { ComposedSummary.make($0, edits: edits) }
    }

    private let backend = BackendService()
    /// The import/transcription in flight, so it can be cancelled.
    private var work: Task<Void, Never>?

    var selected: MeetingRecording? {
        recordings.first { $0.id == selectedID }
    }

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    /// Progress for one job, or nil when something else (or nothing) is running.
    func progress(for job: Job) -> (percent: Double, message: String)? {
        guard case .working(let running, let percent, let message) = phase, running == job else {
            return nil
        }
        return (percent, message)
    }

    func failure(for job: Job) -> String? {
        guard case .failed(let failed, let message) = phase, failed == job else { return nil }
        return message
    }

    init() {
        let permissions = RecordingPermissions()
        self.permissions = permissions
        recorder = MeetingRecorder(permissions: permissions)
        recordings = MeetingLibrary.list()
        select(recordings.first)
    }

    // MARK: - Recording

    /// One button: start, or stop and immediately transcribe what was recorded.
    func toggleRecording(model: String, diarize: Bool = false) async {
        if recorder.isActive {
            guard let recording = await recorder.stop() else { return }
            refresh()
            select(recording)
            await transcribe(recording, model: model, diarize: diarize)
        } else {
            recorder.clearFailure()
            await recorder.start()
            // The new recording is what notes now belong to, even though the
            // list is still showing whatever was open when Record was pressed.
            syncNotes()
        }
    }

    func togglePause() {
        if recorder.state == .paused {
            recorder.resume()
        } else {
            recorder.pause()
        }
    }

    // MARK: - Import

    /// Bring an existing file into the same pipeline — anything ffmpeg reads.
    /// Only its audio is extracted into the meeting folder; the file the user
    /// picked is left untouched where it is.
    ///
    /// `reusing` is a transcription of this same file that another part of the
    /// app has already produced — dropping a video transcribes it, and asking
    /// for a call summary afterwards would otherwise pay for the identical ASR
    /// pass a second time. The backend treats it as a reuse, never a
    /// substitute: an unreadable one falls through to transcribing properly.
    func importFile(at url: URL, model: String, diarize: Bool = false,
                    reusing transcriptionPath: String? = nil) async {
        guard !isBusy else { return }
        phase = .working(job: .transcript, percent: 0,
                         message: "Importing \(url.lastPathComponent)...")
        let task = Task {
            await runImport(url, model: model, diarize: diarize, reusing: transcriptionPath)
        }
        work = task
        await task.value
        work = nil
    }

    /// Stops the import or transcription in flight; the backend process goes
    /// down with it, so a wrong file does not tie up the machine.
    func cancelWork() {
        work?.cancel()
    }

    private func runImport(_ url: URL, model: String, diarize: Bool,
                           reusing transcriptionPath: String?) async {
        let id = MeetingLibrary.newID()
        let recording = MeetingRecording(
            id: id,
            title: url.deletingPathExtension().lastPathComponent,
            startedAt: Date(),
            duration: 0,
            sampleRate: 16_000,
            format: "aac",
            tracks: [:],
            sourceFile: url.path
        )

        do {
            _ = try MeetingLibrary.createFolder(id: id)
            try MeetingLibrary.save(recording)
        } catch {
            phase = .failed(job: .transcript, message: error.localizedDescription)
            return
        }

        let params: [String: Any] = [
            "recording_dir": MeetingLibrary.folder(for: id).path,
            "source_path": url.path
        ]

        var failure: String?
        for await message in await backend.execute(command: "import_recording", params: params) {
            switch message.type {
            case "progress":
                phase = .working(job: .transcript, percent: message.percent ?? 0,
                                 message: message.message ?? "")
            case "error":
                failure = message.message ?? "Unknown error"
            default:
                break
            }
        }

        refresh()

        // Cancelled mid-import: the folder holds a half-extracted file that is
        // not a meeting, so it goes away rather than lingering in the list.
        if Task.isCancelled {
            MeetingLibrary.delete(recording)
            refresh()
            phase = .idle
            return
        }

        guard failure == nil, let imported = recordings.first(where: { $0.id == id }) else {
            MeetingLibrary.delete(recording)
            refresh()
            phase = .failed(job: .transcript, message: failure ?? "Could not read that file")
            return
        }

        phase = .idle
        select(imported)
        await runTranscription(imported, model: model, diarize: diarize,
                               reusing: transcriptionPath)
    }

    // MARK: - Library

    func refresh() {
        recordings = MeetingLibrary.list()
        if let selectedID, !recordings.contains(where: { $0.id == selectedID }) {
            select(recordings.first)
        }
    }

    func select(_ recording: MeetingRecording?) {
        selectedID = recording?.id
        transcript = recording.flatMap(MeetingLibrary.loadTranscript)
        summary = recording.flatMap(MeetingLibrary.loadSummary)
        edits = recording.map(MeetingLibrary.loadEdits) ?? SummaryEdits()
        // Notes follow the meeting, and the file is the truth: the lines typed
        // during a recording were written straight to disk, so re-reading is
        // what picks them up once that recording becomes the selected one.
        loadedNotesID = nil
        syncNotes()
        if case .failed = phase { phase = .idle }
    }

    /// Follow a `piko://meeting/<id>` link: rescan (the meeting may have been
    /// recorded in another window) and select it. Unknown ids are ignored —
    /// a link is not allowed to conjure a recording.
    @discardableResult
    func open(recordingID: String) -> Bool {
        if !recordings.contains(where: { $0.id == recordingID }) { refresh() }
        guard let match = recordings.first(where: { $0.id == recordingID }) else { return false }
        select(match)
        return true
    }

    /// The one field of a meeting a person owns — everything else in meta.json
    /// is written by the recorder or the backend. It is stored there rather
    /// than in an overlay because the backend only ever mutates the keys it
    /// produces (`duration`, `mixed_file`, the track names) and leaves the
    /// title alone, so a rerun cannot undo a rename.
    func rename(_ recording: MeetingRecording, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != recording.title else { return }
        var updated = recording
        updated.title = name
        try? MeetingLibrary.save(updated)
        refresh()
    }

    func delete(_ recording: MeetingRecording) {
        MeetingLibrary.delete(recording)
        refresh()
        if selectedID == recording.id {
            select(recordings.first)
        }
    }

    // MARK: - Transcription

    /// Finalizes the raw tracks (mix + encode) and transcribes them, tagging
    /// each segment with the side that spoke it.
    /// Transcript → structured summary. Reuses the cached one unless `force`.
    func summarize(_ recording: MeetingRecording,
                   params: [String: Any] = [:],
                   force: Bool = false) async {
        guard !isBusy else { return }
        let task = Task { await runSummary(recording, params: params, force: force) }
        work = task
        await task.value
        work = nil
    }

    private func runSummary(_ recording: MeetingRecording,
                            params: [String: Any],
                            force: Bool) async {
        phase = .working(job: .summary, percent: 0, message: "Loading the summarizer...")

        var payload = params
        payload["recording_dir"] = MeetingLibrary.folder(for: recording.id).path
        if force { payload["force"] = true }

        var failure: String?
        for await message in await backend.execute(command: "summarize_meeting", params: payload) {
            switch message.type {
            case "progress":
                phase = .working(job: .summary, percent: message.percent ?? 0,
                                 message: message.message ?? "")

            case "result" where message.success == true:
                summary = message.summary
                failure = nil

            case "error":
                failure = message.message ?? "Unknown error"

            default:
                break
            }
        }

        // A cancelled run may still have written the file.
        if summary == nil {
            summary = MeetingLibrary.loadSummary(for: recording)
        }
        phase = failure.map { Phase.failed(job: .summary, message: $0) } ?? .idle
    }

    func transcribe(_ recording: MeetingRecording,
                    model: String,
                    diarize: Bool = false,
                    force: Bool = false) async {
        guard !isBusy else { return }
        let task = Task {
            await runTranscription(recording, model: model, diarize: diarize, force: force)
        }
        work = task
        await task.value
        work = nil
    }

    private func runTranscription(_ recording: MeetingRecording,
                                  model: String,
                                  diarize: Bool = false,
                                  force: Bool = false,
                                  reusing transcriptionPath: String? = nil) async {
        phase = .working(job: .transcript, percent: 0, message: "Preparing the recording...")

        var params: [String: Any] = [
            "recording_dir": MeetingLibrary.folder(for: recording.id).path,
            "model": model
        ]
        // Re-running transcription leaves the old summary in place: it was
        // built from the previous text, so it is stale until re-run too.
        if force { params["force"] = true }
        // Opt-in, and only sent when its model is already on disk — the
        // backend must never be the thing that starts a download.
        if diarize { params["diarize"] = true }
        // Same speech already transcribed on the captions side: the backend
        // reuses it rather than running an identical ASR pass over the audio
        // it extracted from the very same file.
        if let transcriptionPath { params["transcription_path"] = transcriptionPath }

        var failure: String?
        for await message in await backend.execute(command: "transcribe_meeting", params: params) {
            switch message.type {
            case "progress":
                phase = .working(job: .transcript, percent: message.percent ?? 0,
                                 message: message.message ?? "")

            case "result" where message.success == true:
                failure = nil

            case "error":
                failure = message.message ?? "Unknown error"

            default:
                break
            }
        }

        refresh()

        // A cancelled transcription still leaves the recording itself intact —
        // only the transcript is missing, and it can be retried later.
        if Task.isCancelled {
            phase = .idle
            select(recordings.first { $0.id == recording.id })
            return
        }

        if let failure {
            phase = .failed(job: .transcript, message: failure)
        } else {
            phase = .idle
            select(recordings.first { $0.id == recording.id })
        }
    }
}
