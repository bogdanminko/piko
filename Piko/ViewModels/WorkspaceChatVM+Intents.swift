import Foundation

/// Requests the app can carry out without a model.
///
/// Split out of `WorkspaceChatVM` for length. Kept together because it is one
/// idea: most of what gets typed into a chat beside a loaded file is a button
/// somebody wrote in words, and answering it with prose would spend seconds
/// explaining how to press the button.
extension WorkspaceChatVM {
    /// Something the user asked for that the app can simply do.
    ///
    /// Most of what gets typed here is one of a handful of requests, and none
    /// of them need a language model to be understood — "summarise this" after
    /// dropping a file is a button that happens to have been typed. Matching
    /// them directly is faster, works with no model downloaded, and cannot
    /// hallucinate. Anything unrecognised still goes to the model.
    enum Intent: Equatable {
        case summarise
        case captions
        case burn
        case saveSubtitles
    }

    static let intents: [(Intent, [String])] = [
        (.summarise, ["summar", "саммари", "суммар", "сводк", "конспект"]),
        (.saveSubtitles, ["srt", "vtt", "subtitle file", "сабы", "файл субтитр"]),
        (.burn, ["burn", "вшить", "вжеч", "прожеч", "вписать субтитр"]),
        (.captions, ["caption", "субтитр", "transcribe", "расшифр"])
    ]

    static func intent(in text: String) -> Intent? {
        let lowered = text.lowercased()
        for (intent, needles) in intents where needles.contains(where: lowered.contains) {
            return intent
        }
        return nil
    }

    /// Sending while an answer is still landing **interrupts** it.
    ///
    /// Not a rejection and not a queue. Half a reply is usually enough to know
    /// it is going the wrong way, and the whole value of saying so right then
    /// is that the correction arrives with the thread still in front of the
    /// model — waiting for a paragraph you have already dismissed is the tax
    /// this avoids. The abandoned turn stays in the thread exactly as far as it
    /// got, so the history says what was actually seen.
}
