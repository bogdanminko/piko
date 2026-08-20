import AVFoundation
import SwiftUI

// MARK: - Which pipeline a file belongs to

/// Reading the file instead of asking the user.
///
/// Both signals are free — they come from metadata, not from decoding — and
/// both are about what the recording *is*, not what someone wants from it:
/// a 47-minute screen share is a call that happens to have a picture, a
/// 90-second clip is something to caption. The guess is never hidden: the
/// workspace header offers the other reading in one click.
enum ArtifactRouting {
    /// Past this, a recording is a call rather than a clip.
    static let callDuration: TimeInterval = 10 * 60

    static func focus(for url: URL) async -> ArtifactFocus {
        let asset = AVURLAsset(url: url)
        let hasPicture = (try? await asset.loadTracks(withMediaType: .video))?.isEmpty == false
        guard hasPicture else { return .meeting }

        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        return seconds > callDuration ? .meeting : .video
    }

    /// Hand a file to whichever pipeline fits it and put it in the session.
    ///
    /// One implementation, because a file can arrive from the conversation,
    /// from Choose File…, from a slash command or from New in the sidebar, and
    /// all four have to mean the same thing — including appearing in the thread
    /// as a chip. A file that arrives from the sidebar and is never mentioned
    /// in the conversation is a file the session does not know it has.
    ///
    /// `decided` overrides the metadata guess and is how `/captions` stays
    /// captions: the guess reads anything over ten minutes as a call, which is
    /// right for a drop and wrong for a request.
    @MainActor
    static func open(_ url: URL,
                     as decided: ArtifactFocus? = nil,
                     into workspace: Workspace) async {
        let target: ArtifactFocus
        if let decided {
            target = decided
        } else {
            target = await focus(for: url)
        }

        // A conversation that has already done a piece of work does not take a
        // second file on top of it: that is the mixing this whole arrangement
        // exists to stop. A fresh file gets a fresh session unless the one in
        // front of us is untouched.
        let session = workspace.store.current.isEmpty
            ? workspace.store.current
            : workspace.store.newSession()
        session.name(after: url)

        session.chat.clearWork()
        session.chat.attach(url, focus: target)
        workspace.appState.show(target)

        switch target {
        case .video, .none:
            session.processor.reset()
            session.processor.videoURL = url
        case .meeting:
            await workspace.meeting.importFile(
                at: url,
                model: workspace.modelManager.selectedModelId,
                diarize: workspace.modelManager.diarizationReady)
            session.meetingID = workspace.meeting.selectedID
        }
    }

    /// Open something that already exists — a Library row, a Recent row, a
    /// `piko://` link. In the session that already holds it if there is one,
    /// and in a new session otherwise. Never in whichever conversation happens
    /// to be on screen: reaching into history must not change what the thread
    /// you were reading is about.
    @MainActor
    static func open(_ item: LibraryItem, into workspace: Workspace) {
        switch item.source {
        case .meeting(let recording):
            if let existing = workspace.store.session(holdingMeeting: recording.id) {
                workspace.store.select(existing)
            } else {
                let session = workspace.store.newSession()
                session.name(recording.title)
                session.meetingID = recording.id
            }
            workspace.meeting.select(recording)
            workspace.appState.show(.meeting)
            // Set here rather than left to a focus change: opening the same
            // kind of thing twice in a row does not change the focus, so
            // relying on it means the second one opens nothing.
            workspace.store.current.openArtifact =
                workspace.meeting.composed?.isEmpty == false ? .callSummary : .callTranscript
        case .captions(let entry):
            guard entry.fileExists else { return }
            let url = URL(fileURLWithPath: entry.videoPath)
            if let existing = workspace.store.session(holdingVideo: url) {
                workspace.store.select(existing)
            } else {
                let session = workspace.store.newSession()
                session.name(entry.title)
                session.processor.reset()
                session.processor.videoURL = url
            }
            workspace.appState.show(.video)
            workspace.store.current.openArtifact =
                workspace.store.current.processor.hasTranscript ? .transcript : nil
        }
    }
}

/// The app-level pieces a file has to be handed to, in one value.
///
/// Not a container for its own sake: the same list was being spelled out at
/// every place a file can enter, which is four copies of it and four chances to
/// forget the session and lose the file's mention in the conversation.
@MainActor
struct Workspace {
    let appState: AppState
    let store: SessionStore
    let meeting: MeetingVM
    let modelManager: ModelManagerVM
}
