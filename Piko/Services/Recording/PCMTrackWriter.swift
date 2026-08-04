import AVFoundation
import Foundation

/// Writes one capture source to disk as raw 16 kHz mono signed 16-bit PCM.
///
/// Raw PCM, not WAV or AAC: the header-less stream is crash-proof (a killed app
/// leaves a file that is still fully readable) and needs no encoder on the
/// capture path. `finalize_recording` on the Python side turns the raw tracks
/// into playable m4a. 16 kHz mono is exactly what Whisper/Parakeet consume, and
/// keeps an hour-long meeting at ~115 MB per track before encoding.
final class PCMTrackWriter {
    static let sampleRate: Double = 16_000

    private let handle: FileHandle
    private let outputFormat: AVAudioFormat
    private var inputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    /// Frames written so far, at the output rate — the track's own clock.
    private(set) var framesWritten: Int = 0
    /// Peak level of the most recent chunk, for the UI meter (0...1).
    private(set) var recentPeak: Float = 0

    init(url: URL, sourceSampleRate: Double) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)

        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate, channels: 1, interleaved: true
        ) else {
            throw RecordingError.audioFormatUnavailable
        }
        outputFormat = output
        inputFormat = try Self.makeInputFormat(sourceSampleRate)
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    /// The capture device changed rate mid-recording — rebuild the resampler.
    func updateSourceSampleRate(_ rate: Double) {
        guard abs(rate - inputFormat.sampleRate) > 1,
              let format = try? Self.makeInputFormat(rate) else { return }
        inputFormat = format
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    /// Resample a drained chunk and append it.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty, let converter else { return }

        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        recentPeak = peak

        guard let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        input.frameLength = AVAudioFrameCount(samples.count)
        if let destination = input.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                destination.update(from: base, count: samples.count)
            }
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0,
              let channel = output.int16ChannelData else { return }

        let frames = Int(output.frameLength)
        let data = Data(bytes: channel[0], count: frames * MemoryLayout<Int16>.size)
        handle.write(data)
        framesWritten += frames
    }

    /// Fill a gap (source not started yet, or starved) so both tracks stay
    /// aligned to the same wall clock.
    ///
    /// Worth knowing what this can hide. If the resampler is mistuned — told a
    /// higher source rate than the device delivers — every chunk comes out
    /// short, and padding faithfully makes the difference up in silence. The
    /// file then has exactly the right duration and the wrong contents: speech
    /// sped up, spaced out with quiet. That is why the rate now comes from the
    /// buffers themselves (`MicrophoneCapture.onSampleRateChanged`) rather than
    /// from a format read before the engine started.
    func appendSilence(frames: Int) {
        guard frames > 0 else { return }
        let chunk = 16_000
        var remaining = frames
        while remaining > 0 {
            let count = min(chunk, remaining)
            handle.write(Data(count: count * MemoryLayout<Int16>.size))
            remaining -= count
        }
        framesWritten += frames
    }

    func close() {
        try? handle.close()
    }

    private static func makeInputFormat(_ sampleRate: Double) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate > 0 ? sampleRate : 48_000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.audioFormatUnavailable
        }
        return format
    }
}
