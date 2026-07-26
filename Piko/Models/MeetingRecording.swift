import Foundation

enum RecordingError: LocalizedError {
    case audioFormatUnavailable
    case microphoneDenied
    case noSourcesEnabled
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .audioFormatUnavailable:
            return "Could not set up the 16 kHz recording format"
        case .microphoneDenied:
            return "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
        case .noSourcesEnabled:
            return "Pick at least one source — microphone or system audio"
        case .writeFailed(let detail):
            return "Could not write the recording: \(detail)"
        }
    }
}

/// One recorded meeting on disk: two raw mono tracks plus this metadata.
/// Lives in Application Support (user data — survives "Clear Cache", unlike
/// transcripts and renders, which are derived and live in ~/Library/Caches).
struct MeetingRecording: Codable, Identifiable, Equatable {
    struct Track: Codable, Equatable {
        /// File name inside the recording folder, e.g. "mic.pcm".
        var file: String
        /// Device the track was captured from, for the UI and for debugging.
        var device: String
    }

    var version: Int = 1
    var id: String
    var title: String
    var startedAt: Date
    /// Seconds; 0 while the recording is still running.
    var duration: Double
    var sampleRate: Int
    /// Raw sample format of the tracks — matches ffmpeg's `-f s16le`.
    var format: String
    var tracks: [String: Track]
    /// Set by `finalize_recording`: the mixed, playable file.
    var mixedFile: String?
    /// Imported meetings keep a pointer to the file they came from; the
    /// original is never copied or modified, only its audio is extracted.
    var sourceFile: String?

    enum CodingKeys: String, CodingKey {
        case version, id, title, duration, format, tracks
        case startedAt = "started_at"
        case sampleRate = "sample_rate"
        case mixedFile = "mixed_file"
        case sourceFile = "source_file"
    }

    var micTrack: Track? { tracks["mic"] }
    var systemTrack: Track? { tracks["system"] }
    var isImported: Bool { sourceFile != nil }
}

// MARK: - Transcript

/// `transcribe_meeting` output (transcript.json inside the recording folder).
struct MeetingTranscript: Codable {
    struct Segment: Codable, Identifiable {
        var start: Double
        var end: Double
        /// "me" (microphone) or "them" (system audio).
        var speaker: String
        var text: String

        var id: String { "\(start)-\(end)-\(speaker)" }
    }

    var version: Int
    var language: String?
    var duration: Double
    var segments: [Segment]
    /// Display names per speaker key, e.g. {"me": "You", "them": "Participants"}.
    var speakers: [String: String]
}
