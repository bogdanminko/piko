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

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw MicError.noInputChannels
        }
        sampleRate = format.sampleRate
        deviceName = AudioDevices.defaultInputDevice().flatMap(AudioDevices.name) ?? "Microphone"

        let ring = buffer
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { pcmBuffer, _ in
            Self.forward(pcmBuffer, to: ring)
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
