import AVFoundation
import Foundation
import OSLog

/// Microphone capture on the system's default input device.
///
/// AVAudioEngine (not AVCaptureSession) because all we need is a float tap on
/// the input node; the engine also gives us a configuration-change
/// notification when the user swaps headsets mid-meeting.
final class MicrophoneCapture {
    enum MicError: LocalizedError {
        case noInputChannels
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputChannels:
                return "The default input device has no audio channels"
            case .engineStartFailed(let detail):
                return "Could not start the microphone: \(detail)"
            }
        }
    }

    /// Samples land here as mono float; the recorder drains them. Injected so
    /// the buffer outlives a restart (input device or format changed).
    let buffer: AudioRingBuffer

    private(set) var sampleRate: Double = 48_000
    private(set) var deviceName: String = "Microphone"

    init(buffer: AudioRingBuffer = AudioRingBuffer()) {
        self.buffer = buffer
    }

    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private let log = Logger(subsystem: "dev.bogdanminko.piko", category: "MicrophoneCapture")

    /// Called when the input device or its format changes mid-recording; the
    /// recorder restarts capture so the writer picks up the new sample rate.
    var onConfigurationChanged: (() -> Void)?

    /// The rate the hardware is *actually* delivering, the first time a buffer
    /// proves it differs from what the engine advertised.
    ///
    /// This is not belt and braces. `inputNode.outputFormat(forBus:)` read
    /// before `engine.start()` reports the engine's input format, which is
    /// 48 kHz on this Mac whatever the device does — and AirPods on a call run
    /// their microphone at 16 or 24 kHz. The writer then resampled 48→16 on
    /// audio that was already 16, wrote a third of the frames, and the drain
    /// loop's silence padding made up the difference against the wall clock.
    /// The result was a file of exactly the right length in which every voice
    /// was three times too fast — a 49-minute call, unusable.
    ///
    /// The buffer that arrives carries its own format, and that is the only
    /// account of the sample rate that cannot be wrong.
    var onSampleRateChanged: ((Double) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw MicError.noInputChannels
        }
        sampleRate = format.sampleRate
        deviceName = AudioDevices.defaultInputDevice().flatMap(AudioDevices.name) ?? "Microphone"

        let ring = buffer
        // `nil` rather than the format read above: the node hands over whatever
        // it is really producing, and asking for a specific format here is how
        // a mismatch becomes silent instead of visible.
        input.installTap(onBus: 0, bufferSize: 4_096, format: nil) { [weak self] pcmBuffer, _ in
            Self.forward(pcmBuffer, to: ring)
            let actual = pcmBuffer.format.sampleRate
            guard actual > 0 else { return }
            Task { @MainActor [weak self] in
                guard let self, abs(actual - self.sampleRate) > 1 else { return }
                self.log.info(
                    "Microphone is really at \(actual) Hz, not \(self.sampleRate) Hz — correcting"
                )
                self.sampleRate = actual
                self.onSampleRateChanged?(actual)
            }
        }

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChanged?()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw MicError.engineStartFailed(error.localizedDescription)
        }
        log.info("Microphone capture started on \(self.deviceName, privacy: .public) @ \(self.sampleRate) Hz")
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
    }

    deinit {
        stop()
    }

    /// Downmix to mono and hand the samples to the ring buffer.
    private static func forward(_ pcmBuffer: AVAudioPCMBuffer, to ring: AudioRingBuffer) {
        guard let channels = pcmBuffer.floatChannelData else { return }
        let frames = Int(pcmBuffer.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(pcmBuffer.format.channelCount)

        if channelCount == 1 {
            ring.write(channels[0], count: frames)
            return
        }

        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let source = channels[channel]
            for frame in 0..<frames {
                mono[frame] += source[frame]
            }
        }
        let scale = 1 / Float(channelCount)
        for frame in 0..<frames {
            mono[frame] *= scale
        }
        mono.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            ring.write(base, count: frames)
        }
    }
}
