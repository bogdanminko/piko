import Foundation

/// One session in the Library — the join of the two things Piko already keeps
/// on disk: meetings (folders under Application Support) and captions runs
/// (history.json). The Library is deliberately not a third store: "what did I
/// work on last week" is one question, so it reads the two existing sources
/// instead of maintaining its own copy that could drift out of sync.
struct LibraryItem: Identifiable {
    enum Source {
        case meeting(MeetingRecording)
        case captions(HistoryEntry)
    }

    /// How far a session got. Derived from the files on disk on every scan
    /// rather than stored: `transcript.json` / `summary.json` are the only
    /// truth about what exists, so a rerun — or a file removed behind the
    /// app's back — can never leave a stale badge behind.
    enum Stage {
        case recorded
        case transcribed
        case summarized
        case captioned(String)
        case missing

        var label: String {
            switch self {
            case .recorded: "Recorded"
            case .transcribed: "Transcribed"
            case .summarized: "Summarized"
            case .captioned(let style): "Captioned · \(style)"
            case .missing: "File missing"
            }
        }

        /// Only a finished session reads as finished; anything mid-pipeline
        /// stays neutral so the list doesn't glow green from end to end.
        var isComplete: Bool {
            switch self {
            case .summarized, .captioned: true
            default: false
            }
        }
    }

    let source: Source
    let title: String
    let subtitle: String
    let date: Date
    /// Seconds. A meeting knows its own length; a captions run does not.
    let duration: Double?
    let stage: Stage

    /// Prefixed per source: a meeting id and a video path can never collide,
    /// but the list mixes both and SwiftUI needs one namespace.
    var id: String {
        switch source {
        case .meeting(let recording): "meeting:\(recording.id)"
        case .captions(let entry): "captions:\(entry.videoPath)"
        }
    }

    var recording: MeetingRecording? {
        if case .meeting(let recording) = source { return recording }
        return nil
    }

    var captionsEntry: HistoryEntry? {
        if case .captions(let entry) = source { return entry }
        return nil
    }

    /// False only for a captions run whose source video has moved or been
    /// deleted — a meeting owns its folder, so it is always openable.
    var isAvailable: Bool {
        if case .missing = stage { return false }
        return true
    }

    var hasSummary: Bool {
        if case .summarized = stage { return true }
        return false
    }

    /// Where "Reveal in Finder" points: the meeting's folder (audio,
    /// transcript, summary all live there) or the video that was captioned.
    var revealURL: URL? {
        switch source {
        case .meeting(let recording): MeetingLibrary.folder(for: recording.id)
        case .captions(let entry): entry.fileExists ? URL(fileURLWithPath: entry.videoPath) : nil
        }
    }

    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Building the list

extension LibraryItem {
    init(meeting recording: MeetingRecording) {
        source = .meeting(recording)
        title = recording.title
        subtitle = Self.meetingSubtitle(recording)
        date = recording.startedAt
        duration = recording.duration
        stage = Self.meetingStage(recording)
    }

    init(captions entry: HistoryEntry) {
        source = .captions(entry)
        title = entry.title
        subtitle = "\(entry.kind) · \(entry.wordCount) words"
        date = entry.date
        duration = nil
        stage = entry.fileExists ? .captioned(entry.style) : .missing
    }

    private static func meetingStage(_ recording: MeetingRecording) -> Stage {
        if MeetingLibrary.hasSummary(id: recording.id) { return .summarized }
        if MeetingLibrary.hasTranscript(id: recording.id) { return .transcribed }
        return .recorded
    }

    private static func meetingSubtitle(_ recording: MeetingRecording) -> String {
        if let source = recording.sourceFile {
            return "Meeting · imported from \(URL(fileURLWithPath: source).lastPathComponent)"
        }
        var parts: [String] = []
        if recording.micTrack != nil { parts.append("microphone") }
        if recording.systemTrack != nil { parts.append("system audio") }
        return parts.isEmpty ? "Meeting" : "Meeting · " + parts.joined(separator: " + ")
    }

    /// Both verticals in one list, newest first.
    static func all(meetings: [MeetingRecording], captions: [HistoryEntry]) -> [LibraryItem] {
        (meetings.map(LibraryItem.init(meeting:)) + captions.map(LibraryItem.init(captions:)))
            .sorted { $0.date > $1.date }
    }

    /// Grouped by calendar day, newest first — the shape a history is actually
    /// read in ("what did I do on Tuesday"), not one flat run of rows.
    static func byDay(_ items: [LibraryItem]) -> [LibraryDay] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: items) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { LibraryDay(date: $0, items: groups[$0] ?? []) }
    }
}

/// One day's worth of sessions, as the Library renders them.
struct LibraryDay: Identifiable {
    let date: Date
    let items: [LibraryItem]

    var id: Date { date }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
}
