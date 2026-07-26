import Foundation
import Observation
import OSLog

/// The recorder the UI talks to: owns both captures, the disk session and the
/// recording's metadata.
///
/// Microphone and system audio are kept as two separate tracks on purpose.
/// They give speaker attribution ("you" vs "the call") for free, without
/// diarization — which is what the Meeting Summary skill needs to link every
/// claim back to a moment in the recording (docs/PRODUCT.md).
@MainActor
@Observable
final class MeetingRecorder {
    enum State: Equatable {
        case idle
        case starting
        case recording
        case paused
        case finishing
        case failed(String)
    }

    private static let micSourceKey = "piko.record.microphone"
    private static let systemSourceKey = "piko.record.systemAudio"

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// 0...1 peak meters for the two tracks.
    private(set) var micLevel: Double = 0
    private(set) var systemLevel: Double = 0
    /// Non-fatal problem worth showing while recording continues
    /// (e.g. system audio unavailable, so this is a mic-only recording).
    private(set) var warning: String?
    /// Set when a recording finishes — the screen picks it up from here.
    private(set) var lastRecording: MeetingRecording?

    var recordMicrophone: Bool {
        didSet { UserDefaults.standard.set(recordMicrophone, forKey: Self.micSourceKey) }
    }

    var recordSystemAudio: Bool {
        didSet { UserDefaults.standard.set(recordSystemAudio, forKey: Self.systemSourceKey) }
    }

    var isActive: Bool { state == .recording || state == .paused }

    private let permissions: RecordingPermissions
    private let log = Logger(subsystem: "dev.bogdanminko.piko", category: "MeetingRecorder")

    private var micCapture: MicrophoneCapture?
    private var tapCapture: SystemAudioTap?
    private var session: RecordingSession?
    private var recording: MeetingRecording?

    init(permissions: RecordingPermissions) {
        self.permissions = permissions
        let defaults = UserDefaults.standard
        recordMicrophone = defaults.object(forKey: Self.micSourceKey) as? Bool ?? true
        recordSystemAudio = defaults.object(forKey: Self.systemSourceKey) as? Bool ?? true
        Self.repairInterruptedRecordings()
    }

    // MARK: - Control

    func start() async {
        guard state == .idle || isFailed else { return }
        guard recordMicrophone || recordSystemAudio else {
            state = .failed(RecordingError.noSourcesEnabled.localizedDescription)
            return
        }
        state = .starting
        warning = nil
        elapsed = 0
        micLevel = 0
        systemLevel = 0

        if recordMicrophone {
            permissions.refreshMic()
            if permissions.mic == .notDetermined {
                await permissions.requestMic()
            }
            guard permissions.mic == .granted else {
                state = .failed(RecordingError.microphoneDenied.localizedDescription)
                return
            }
        }

        do {
            try await beginRecording()
            state = .recording
        } catch {
            teardownCaptures()
            state = .failed(error.localizedDescription)
        }
    }

    func pause() {
        guard state == .recording else { return }
        session?.setPaused(true)
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        session?.setPaused(false)
        state = .recording
    }

    /// Stops capture, flushes both tracks and returns the finished recording.
    @discardableResult
    func stop() async -> MeetingRecording? {
        guard isActive, let session, var recording else { return nil }
        state = .finishing
        teardownCaptures()

        let duration = await withCheckedContinuation { continuation in
            session.finish { continuation.resume(returning: $0) }
        }

        recording.duration = duration
        try? MeetingLibrary.save(recording)
        self.session = nil
        self.recording = nil
        lastRecording = recording
        elapsed = duration
        micLevel = 0
        systemLevel = 0
        state = .idle
        log.info("Recording \(recording.id, privacy: .public) finished: \(duration, format: .fixed(precision: 1))s")
        return recording
    }

    func clearFailure() {
        if isFailed { state = .idle }
    }

    // MARK: - Wiring

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func beginRecording() async throws {
        let id = MeetingLibrary.newID()
        let folder = try MeetingLibrary.createFolder(id: id)

        var tracks: [String: MeetingRecording.Track] = [:]
        var micPair: (buffer: AudioRingBuffer, writer: PCMTrackWriter)?
        var systemPair: (buffer: AudioRingBuffer, writer: PCMTrackWriter)?

        if recordMicrophone {
            let capture = MicrophoneCapture()
            try capture.start()
            capture.onConfigurationChanged = { [weak self] in
                Task { @MainActor in self?.restartMicrophone() }
            }
            let writer = try PCMTrackWriter(
                url: folder.appendingPathComponent("mic.pcm"), sourceSampleRate: capture.sampleRate
            )
            micCapture = capture
            micPair = (capture.buffer, writer)
            tracks["mic"] = MeetingRecording.Track(file: "mic.pcm", device: capture.deviceName)
        }

        if recordSystemAudio {
            let tap = SystemAudioTap()
            do {
                try tap.start()
                tap.onDefaultOutputDeviceChanged = { [weak self] in
                    Task { @MainActor in self?.restartSystemAudio() }
                }
                let writer = try PCMTrackWriter(
                    url: folder.appendingPathComponent("system.pcm"), sourceSampleRate: tap.sampleRate
                )
                tapCapture = tap
                systemPair = (tap.buffer, writer)
                tracks["system"] = MeetingRecording.Track(file: "system.pcm", device: tap.deviceName)
            } catch {
                // Mic-only is still a usable meeting recording — don't lose the
                // take over a missing Audio Capture grant.
                log.error("System audio capture unavailable: \(error.localizedDescription, privacy: .public)")
                guard micPair != nil else { throw error }
                warning = "Recording microphone only — system audio is unavailable. "
                    + "Check System Settings → Privacy & Security → Audio Capture."
            }
        }

        guard micPair != nil || systemPair != nil else {
            throw RecordingError.noSourcesEnabled
        }

        let recording = MeetingRecording(
            id: id,
            title: Self.makeTitle(),
            startedAt: Date(),
            duration: 0,
            sampleRate: Int(PCMTrackWriter.sampleRate),
            format: "s16le",
            tracks: tracks
        )
        try MeetingLibrary.save(recording)
        self.recording = recording

        let session = RecordingSession(mic: micPair, system: systemPair)
        session.onMeters = { [weak self] meters in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.micLevel = Double(min(1, meters.mic))
                self.systemLevel = Double(min(1, meters.system))
                self.elapsed = meters.elapsed
            }
        }
        session.start()
        self.session = session
    }

    private func teardownCaptures() {
        micCapture?.onConfigurationChanged = nil
        tapCapture?.onDefaultOutputDeviceChanged = nil
        micCapture?.stop()
        tapCapture?.stop()
        micCapture = nil
        tapCapture = nil
    }

    /// Input device or format changed — restart the engine on the same ring
    /// buffer so the track keeps flowing (the writer picks up the new rate).
    private func restartMicrophone() {
        guard isActive, let capture = micCapture else { return }
        capture.stop()
        do {
            try capture.start()
            session?.updateMicSampleRate(capture.sampleRate)
        } catch {
            warning = "Microphone stopped: \(error.localizedDescription)"
            log.error("Microphone restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The tap is bound to one output device; when the default changes
    /// (headphones plugged in) it has to be rebuilt against the new one.
    private func restartSystemAudio() {
        guard isActive, let tap = tapCapture else { return }
        tap.stop()
        do {
            try tap.start()
            session?.updateSystemSampleRate(tap.sampleRate)
        } catch {
            warning = "System audio stopped after the output device changed: \(error.localizedDescription)"
            log.error("Tap restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private static func makeTitle() -> String {
        "Meeting · \(MeetingLibrary.timestampTitle())"
    }

    /// A recording whose app died mid-take keeps its audio (raw PCM survives
    /// anything) but never got its duration written. Recover it from the track
    /// size so the meeting still shows up with a sane length.
    private static func repairInterruptedRecordings() {
        for recording in MeetingLibrary.list() where recording.duration == 0 {
            var repaired = recording
            let folder = MeetingLibrary.folder(for: recording.id)
            let longest = recording.tracks.values
                .map { folder.appendingPathComponent($0.file) }
                .compactMap { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) }
                .max() ?? 0
            let seconds = Double(longest) / (2 * PCMTrackWriter.sampleRate)
            guard seconds > 1 else { continue }
            repaired.duration = seconds
            try? MeetingLibrary.save(repaired)
        }
    }
}
