import AVFoundation
import Observation
import SwiftUI

/// The recording, playable, so a timecode is a place you can go rather than a
/// number you have to trust.
///
/// This is the other half of a promise the app has been making since the first
/// summary: every claim links back to the second it was said. A link that
/// cannot be followed is a citation in a book with no library — you can read
/// "00:34:08" and still have no way of hearing what was actually said there.
///
/// Deliberately audio-shaped and small. It is not a media player: no scrubbing
/// UI beyond a bar, no rate control, no playlist. One file, one position, and a
/// `seek` anything on screen can call.
@MainActor
@Observable
final class ArtifactPlayer {
    private(set) var url: URL?
    private(set) var isPlaying = false
    private(set) var current: Double = 0
    private(set) var duration: Double = 0

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?

    /// Point it at a file. Loading the same one again is a no-op, so the
    /// position survives a view rebuild.
    func load(_ url: URL?) {
        guard url != self.url else { return }
        teardown()
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }

        let player = AVPlayer(url: url)
        self.player = player
        // Four times a second: enough for a progress bar to look alive, few
        // enough that it is not a timer redrawing a transcript.
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.current = time.seconds
                if self.duration == 0,
                   let seconds = player.currentItem?.duration.seconds,
                   seconds.isFinite {
                    self.duration = seconds
                }
            }
        }
    }

    /// Jump to a second and start playing.
    ///
    /// Playing rather than parking there on purpose: nobody clicks a timecode
    /// to look at a number. A tenth of a second before the mark, because the
    /// first syllable of the line is what tells you the jump landed.
    func seek(to seconds: Double) {
        guard let player else { return }
        let target = max(0, seconds - 0.35)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlaying = true
        current = target
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func scrub(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        current = seconds
    }

    private func teardown() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        isPlaying = false
        current = 0
        duration = 0
    }

    deinit {
        if let observer { player?.removeTimeObserver(observer) }
        player?.pause()
    }
}

extension ArtifactPlayer {
    /// What a session has to play: a call's mix, or the video the captions came
    /// from. Both answer "what was actually said at 04:12", which is the only
    /// question this player exists for.
    ///
    /// Static because two views need the same answer — the thread, to know
    /// whether its timecodes are places, and the panel, to draw the bar — and
    /// two copies of this rule would eventually disagree.
    @MainActor
    static func audioURL(for session: ChatSession, meeting: MeetingVM) -> URL? {
        if let id = session.meetingID, let recording = meeting.selected, recording.id == id {
            let folder = MeetingLibrary.folder(for: id)
            let mixed = folder.appendingPathComponent(recording.mixedFile ?? "meeting.m4a")
            return FileManager.default.fileExists(atPath: mixed.path) ? mixed : nil
        }
        return session.processor.videoURL
    }
}

// MARK: - Reaching it from anywhere on screen

/// A timecode is drawn in a dozen places — transcript rows, action items, the
/// summary's citations — and threading a callback down to each of them would
/// mean touching every one of those views and every view between. The
/// environment is what this is for: the panel that owns the player publishes a
/// seek, and every `Timecode` already on screen becomes a place you can go.
private struct SeekActionKey: EnvironmentKey {
    static let defaultValue: ((Double) -> Void)? = nil
}

extension EnvironmentValues {
    var seekToTime: ((Double) -> Void)? {
        get { self[SeekActionKey.self] }
        set { self[SeekActionKey.self] = newValue }
    }
}
