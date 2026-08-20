import SwiftUI

/// What the workspace does with a typed request, and what the model is allowed
/// to read while answering one.
///
/// Split out of `ArtifactScreen` for length alone — these two concerns are the
/// seam between the conversation and the work, and they belong beside each
/// other rather than buried among the layout.
extension ArtifactEntry {
    /// Requests the app can simply carry out, answered by doing them.
    ///
    /// "Summarise this" after dropping a video is a button somebody typed.
    /// Sending it to a language model would spend seconds to produce a
    /// paragraph explaining how to press that button — and, as it turned out,
    /// telling them to drop a file they had already dropped.
    func handle(_ intent: WorkspaceChatVM.Intent) -> String? {
        switch intent {
        case .summarise:
            guard let url = processor.videoURL else { return nil }
            Task {
                await meeting.importFile(at: url,
                                         model: modelManager.selectedModelId,
                                         diarize: modelManager.diarizationReady,
                                         reusing: processor.transcriptionPath)
            }
            return "Summarising it as a call — reusing the transcript above, so this "
                + "costs no second pass over the audio."
        case .saveSubtitles:
            guard processor.srtURL != nil else { return nil }
            processor.saveSRT()
            return "Saved."
        case .burn:
            guard processor.hasTranscript else { return nil }
            chat.openStyles()
            return "Pick a look below. Burning is the one step that re-encodes the "
                + "video, so it waits for you to press it."
        case .captions:
            guard processor.videoURL == nil else { return nil }
            onOpenFile(.video)
            return "Pick a video and I'll transcribe it."
        }
    }

    /// One sentence telling the model what is loaded.
    var chatContext: String {
        if let url = processor.videoURL {
            let name = url.lastPathComponent
            guard processor.hasTranscript else { return "\(name) is loaded and transcribing." }
            return "\(name) is loaded and already transcribed — its subtitle files are "
                + "written and the user can ask you to summarise it as a call."
        }
        if let meeting = meeting.selected {
            return "the recording \"\(meeting.title)\" is open."
        }
        return "nothing is loaded."
    }
}
