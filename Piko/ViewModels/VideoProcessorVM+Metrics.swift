import Foundation

/// What the run cost, derived from the timestamps the pipeline recorded.
///
/// All of them cover the full first pass and deliberately not the style
/// re-renders that follow: "37 s" should mean what the machine did with the
/// file, not how long someone spent trying looks.
extension VideoProcessorVM {
    var processingSeconds: Double? {
        guard let started = runStartedAt, let finished = runFinishedAt else { return nil }
        return finished.timeIntervalSince(started)
    }

    /// Words transcribed per second of processing.
    var wordsPerSecond: Double? {
        guard let secs = processingSeconds, secs > 0, wordCount > 0 else { return nil }
        return Double(wordCount) / secs
    }

    /// The standard ASR speed metric: audio duration / processing time
    /// ("2.4× realtime").
    var realtimeFactor: Double? {
        guard let secs = processingSeconds, secs > 0, mediaDuration > 0 else { return nil }
        return mediaDuration / secs
    }
}
