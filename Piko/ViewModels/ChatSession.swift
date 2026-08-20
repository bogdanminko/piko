import Foundation
import Observation

/// One conversation and everything it produced.
///
/// The app had exactly one of each view model, which meant it had exactly one
/// session pretending to be many: open a recording from history and its
/// artifacts joined whatever conversation happened to be on screen, because
/// there was nowhere else for them to be. A thread and its artifacts are the
/// same object — that is what "session" means — so they are held together here
/// and nowhere else.
///
/// `MeetingVM` is deliberately *not* one of them. There is one recorder and one
/// folder of recordings on this Mac, so the library is app-level; a session
/// holds the id of the recording it is about and the shell selects it on the
/// way in. Everything that belongs to one conversation — its thread, its
/// captions run, which artifact was open — lives here.
@MainActor
@Observable
final class ChatSession: Identifiable {
    private(set) var id = UUID()
    let startedAt: Date

    /// Named after whatever it was given, and only once. Twelve rows reading
    /// "New session" is a list nobody can use, and a title regenerated on every
    /// rerun is a title nobody can correct.
    var title: String
    private(set) var isNamed = false

    let chat = WorkspaceChatVM()
    let processor = VideoProcessorVM()
    /// The recording this conversation is about, playable. Per session for the
    /// same reason everything else here is: two conversations open on two calls
    /// must not share one playhead.
    let player = ArtifactPlayer()

    /// The recording this conversation is about, if it is about one.
    var meetingID: String?

    /// Where the reader was. Part of the session because coming back to a
    /// conversation should come back to *it*, not to a conversation with the
    /// panel shut and the transcript to find again.
    var openArtifact: WorkspaceArtifact?
    var isPanelExpanded = false

    /// A second this conversation was opened *at* — a `piko://…?t=` link
    /// followed from Reminders, say. Held rather than acted on immediately
    /// because the audio is not loaded at the moment the link arrives, and a
    /// seek into a player with no file is a jump that silently does nothing.
    var pendingSeek: Double?

    init(startedAt: Date = Date(), title: String = "New session") {
        self.startedAt = startedAt
        self.title = title
    }

    // MARK: - On disk

    /// Restore a conversation. The artifacts it points at are *not* restored
    /// here — the video path goes back on the processor and the transcript
    /// re-derives from the ASR cache the first time this session is opened,
    /// because a stored copy of a transcript is a second truth that can drift
    /// from the first.
    convenience init(_ record: SessionRecord) {
        self.init(startedAt: record.startedAt, title: record.title)
        id = record.id
        isNamed = record.isNamed
        meetingID = record.meetingID
        openArtifact = record.openArtifact.flatMap(WorkspaceArtifact.init(rawValue:))
        isPanelExpanded = record.isPanelExpanded
        chat.turns = SessionArchive.persistable(record.turns)
        if let path = record.videoPath, FileManager.default.fileExists(atPath: path) {
            processor.videoURL = URL(fileURLWithPath: path)
        }
    }

    var record: SessionRecord {
        SessionRecord(
            id: id,
            title: title,
            isNamed: isNamed,
            startedAt: startedAt,
            meetingID: meetingID,
            videoPath: processor.videoURL?.path,
            openArtifact: openArtifact?.rawValue,
            isPanelExpanded: isPanelExpanded,
            turns: SessionArchive.persistable(chat.turns)
        )
    }

    /// Nothing has been said and nothing handed over. Used to keep the sidebar
    /// from filling with identical blank rows.
    var isEmpty: Bool {
        chat.turns.isEmpty && processor.videoURL == nil && meetingID == nil
    }

    func name(after url: URL) {
        name(url.deletingPathExtension().lastPathComponent)
    }

    func name(_ candidate: String) {
        guard !isNamed else { return }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        title = trimmed
        isNamed = true
    }

    /// A rename by hand outranks anything derived, permanently.
    func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        title = trimmed
        isNamed = true
    }
}

/// Every conversation, newest first, backed by one file each.
///
/// Saves are debounced rather than immediate: a streaming answer changes the
/// last turn thirty times a second, and writing the file on each of those would
/// be a disk write per token for a document nobody is reading yet.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [ChatSession] = []
    private(set) var currentID: ChatSession.ID

    /// Runs for every session the store makes, so shell-level wiring is
    /// attached once at the one place sessions are born rather than remembered
    /// at each of the four places one can be started from.
    var onCreate: ((ChatSession) -> Void)?

    private var pendingSaves: [ChatSession.ID: Task<Void, Never>] = [:]

    init() {
        let restored = SessionArchive.loadAll().map(ChatSession.init)
        if let newest = restored.first {
            sessions = restored
            currentID = newest.id
        } else {
            let first = ChatSession()
            sessions = [first]
            currentID = first.id
        }
    }

    /// Write this conversation out, a beat after it stops changing.
    func scheduleSave(_ session: ChatSession) {
        pendingSaves[session.id]?.cancel()
        pendingSaves[session.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            SessionArchive.save(session.record)
            self?.pendingSaves[session.id] = nil
        }
    }

    /// Everything, now — for the moment the app is going away and a debounce
    /// would never fire.
    func saveAll() {
        for session in sessions where !session.isEmpty {
            SessionArchive.save(session.record)
        }
    }

    var current: ChatSession {
        sessions.first { $0.id == currentID } ?? sessions[0]
    }

    /// A new conversation, immediately. It asks nothing: "New session" is not a
    /// question about what you are about to do, and answering one before you
    /// have a file in hand is the entrance the workspace was built to remove.
    @discardableResult
    func newSession() -> ChatSession {
        // An untouched session already *is* a new one. Making a second would
        // fill the sidebar with rows that differ in nothing.
        if current.isEmpty { return current }
        let session = ChatSession()
        onCreate?(session)
        sessions.insert(session, at: 0)
        currentID = session.id
        return session
    }

    func select(_ session: ChatSession) {
        currentID = session.id
    }

    /// The session already holding this artifact, if any. Opening something
    /// from history means opening *its* conversation — dropping it into
    /// whichever one happens to be on screen is the bleed this store exists to
    /// stop.
    func session(holdingMeeting meetingID: String) -> ChatSession? {
        sessions.first { $0.meetingID == meetingID }
    }

    func session(holdingVideo url: URL) -> ChatSession? {
        sessions.first { $0.processor.videoURL?.path == url.path }
    }

    func delete(_ session: ChatSession) {
        pendingSaves[session.id]?.cancel()
        pendingSaves[session.id] = nil
        SessionArchive.delete(session.id)
        session.processor.cancel()
        sessions.removeAll { $0.id == session.id }
        if sessions.isEmpty {
            let fresh = ChatSession()
            onCreate?(fresh)
            sessions = [fresh]
        }
        if !sessions.contains(where: { $0.id == currentID }) {
            currentID = sessions[0].id
        }
    }
}
