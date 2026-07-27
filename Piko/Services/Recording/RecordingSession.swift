import Foundation

/// The drain loop behind a recording: every 100 ms it pulls both capture ring
/// buffers, resamples to 16 kHz and appends to disk.
///
/// The wall clock is authoritative, not the sample counters. A source that
/// starts late (the tap needs ~200 ms to spin up) or drops out (device swap)
/// gets silence padded into its track, so `mic.pcm` and `system.pcm` stay
/// sample-aligned — which is what makes "who spoke when" a matter of comparing
/// energy between two files instead of running diarization.
///
/// Everything runs on a private serial queue; the UI only receives meters.
final class RecordingSession: @unchecked Sendable {
    struct Meters: Sendable {
        let mic: Float
        let system: Float
        let elapsed: TimeInterval
    }

    private final class Track {
        let buffer: AudioRingBuffer
        let writer: PCMTrackWriter
        var level: Float = 0

        init(buffer: AudioRingBuffer, writer: PCMTrackWriter) {
            self.buffer = buffer
            self.writer = writer
        }
    }

    /// Pad a track only once it is at least this far behind the clock — below
    /// that the gap is just buffering jitter.
    private static let paddingThreshold = 0.1

    private let queue = DispatchQueue(label: "dev.bogdanminko.piko.recording-session", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let mic: Track?
    private let system: Track?

    private var startTime = Date()
    private var pausedTotal: TimeInterval = 0
    private var pauseStarted: Date?
    private var finished = false

    /// Delivered on the session's own queue.
    var onMeters: ((Meters) -> Void)?

    init(mic: (buffer: AudioRingBuffer, writer: PCMTrackWriter)?,
         system: (buffer: AudioRingBuffer, writer: PCMTrackWriter)?) {
        self.mic = mic.map { Track(buffer: $0.buffer, writer: $0.writer) }
        self.system = system.map { Track(buffer: $0.buffer, writer: $0.writer) }
    }

    // MARK: - Control

    func start() {
        queue.async {
            self.startTime = Date()
            self.pausedTotal = 0
            self.pauseStarted = nil
            // Drop whatever the captures buffered before the clock started —
            // the samples are discarded, hence the ignored return.
            _ = self.mic?.buffer.drain()
            _ = self.system?.buffer.drain()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async {
            if paused {
                guard self.pauseStarted == nil else { return }
                self.pauseStarted = Date()
            } else {
                guard let started = self.pauseStarted else { return }
                self.pausedTotal += Date().timeIntervalSince(started)
                self.pauseStarted = nil
            }
        }
    }

    func updateMicSampleRate(_ rate: Double) {
        queue.async { self.mic?.writer.updateSourceSampleRate(rate) }
    }

    func updateSystemSampleRate(_ rate: Double) {
        queue.async { self.system?.writer.updateSourceSampleRate(rate) }
    }

    /// Stops the loop, flushes what is left and closes the files.
    /// - Parameter completion: called on the main queue with the final duration.
    func finish(completion: @escaping @Sendable (TimeInterval) -> Void) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            self.timer?.cancel()
            self.timer = nil
            self.tick(final: true)
            let duration = self.elapsed()
            self.mic?.writer.close()
            self.system?.writer.close()
            DispatchQueue.main.async { completion(duration) }
        }
    }

    // MARK: - Drain loop

    private func elapsed() -> TimeInterval {
        var value = Date().timeIntervalSince(startTime) - pausedTotal
        if let pauseStarted {
            value -= Date().timeIntervalSince(pauseStarted)
        }
        return max(0, value)
    }

    private func tick(final: Bool = false) {
        let isPaused = pauseStarted != nil
        let elapsed = self.elapsed()
        let expectedFrames = Int(elapsed * PCMTrackWriter.sampleRate)

        for track in [mic, system].compactMap({ $0 }) {
            let samples = track.buffer.drain()

            // While paused the captures keep running; their samples are dropped
            // so the recording contains only what the user meant to record.
            guard !isPaused else {
                track.level = 0
                continue
            }

            if samples.isEmpty {
                let deficit = expectedFrames - track.writer.framesWritten
                if Double(deficit) > Self.paddingThreshold * PCMTrackWriter.sampleRate {
                    track.writer.appendSilence(frames: deficit)
                }
                // Meters fall off rather than freezing on the last peak.
                track.level *= 0.6
            } else {
                track.writer.append(samples)
                track.level = max(track.writer.recentPeak, track.level * 0.6)
            }
        }

        if !final {
            onMeters?(Meters(mic: mic?.level ?? 0, system: system?.level ?? 0, elapsed: elapsed))
        }
    }
}
