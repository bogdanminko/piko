import CoreAudio
import Foundation
import OSLog

/// System-audio capture through a Core Audio process tap (macOS 14.2+).
///
/// Why a tap and not ScreenCaptureKit: a tap needs only the "Audio Capture"
/// TCC grant (`NSAudioCaptureUsageDescription`), while SCStream would demand
/// full Screen Recording — a much larger ask for a meeting recorder, with a
/// recurring re-approval nag since macOS 15.
///
/// The shape below is the one Core Audio actually supports: a global process
/// tap becomes a *sub-tap* of a private aggregate device whose main sub-device
/// is the current default output. An IOProc on that aggregate then delivers the
/// system mixdown. Driving the tap without an aggregate, or pointing
/// AVAudioEngine at the aggregate, both fail silently (zero samples).
@available(macOS 14.2, *)
final class SystemAudioTap {
    enum TapError: LocalizedError {
        case noDefaultOutputDevice(OSStatus)
        case tapCreationFailed(OSStatus)
        case tapFormatUnavailable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noDefaultOutputDevice(let status):
                return "No default output device (status \(status))"
            case .tapCreationFailed(let status):
                // The usual cause is a missing Audio Capture permission.
                return "Could not tap system audio (status \(status))"
            case .tapFormatUnavailable(let status):
                return "Could not read the tap's audio format (status \(status))"
            case .aggregateCreationFailed(let status):
                return "Could not create the capture device (status \(status))"
            case .ioProcCreationFailed(let status):
                return "Could not attach to the capture device (status \(status))"
            case .startFailed(let status):
                return "Could not start system audio capture (status \(status))"
            }
        }
    }

    /// Samples land here as mono float; the recorder drains them. Injected so
    /// the buffer outlives a tap restart (default output device changed).
    let buffer: AudioRingBuffer

    private(set) var sampleRate: Double = 48_000
    /// Name of the output device being tapped, for the recording metadata.
    private(set) var deviceName: String = "System Audio"

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private let queue = DispatchQueue(label: "dev.bogdanminko.piko.system-audio", qos: .userInitiated)
    private let log = Logger(subsystem: "dev.bogdanminko.piko", category: "SystemAudioTap")

    /// Called when the default output device changes mid-recording (headphones
    /// plugged in). The tap is bound to one device, so the recorder restarts it.
    var onDefaultOutputDeviceChanged: (() -> Void)?

    init(buffer: AudioRingBuffer = AudioRingBuffer()) {
        self.buffer = buffer
    }

    // MARK: - Lifecycle

    func start() throws {
        guard let outputDevice = AudioDevices.defaultOutputDevice(),
              let outputUID = AudioDevices.uid(of: outputDevice) else {
            throw TapError.noDefaultOutputDevice(noErr)
        }
        deviceName = AudioDevices.name(of: outputDevice) ?? "System Audio"

        // Empty exclusion list = every process. Mono keeps the tap's own
        // mixdown cheap; the recording is mono 16 kHz anyway.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Piko Meeting Tap"
        description.isPrivate = true
        // Never mute what the user is listening to.
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError.tapCreationFailed(status)
        }

        let asbd = try tapFormat()
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000

        let tapUID = description.uuid.uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Piko Meeting Recorder",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            // Private: never shows up in Sound settings or other apps.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]

        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            stop()
            throw TapError.aggregateCreationFailed(status)
        }

        let ring = buffer
        let channelsPerFrame = Int(asbd.mChannelsPerFrame)
        let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inputData, _, _, _ in
            Self.forward(inputData, channels: channelsPerFrame, interleaved: isInterleaved, to: ring)
        }
        guard status == noErr, procID != nil else {
            stop()
            throw TapError.ioProcCreationFailed(status)
        }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw TapError.startFailed(status)
        }

        installDefaultOutputDeviceListener()
        log.info("System audio tap started on \(self.deviceName, privacy: .public) @ \(self.sampleRate) Hz")
    }

    func stop() {
        removeDefaultOutputDeviceListener()
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        stop()
    }

    // MARK: - Audio callback

    /// Copies one IOProc buffer list into the ring buffer as mono float.
    /// Realtime context: no allocation, no locks beyond the ring's unfair lock.
    private static func forward(
        _ bufferList: UnsafePointer<AudioBufferList>,
        channels: Int,
        interleaved: Bool,
        to ring: AudioRingBuffer
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first, let data = first.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        let totalFloats = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard totalFloats > 0 else { return }

        let bufferChannels = Int(first.mNumberChannels)
        if !interleaved || bufferChannels <= 1 || channels <= 1 {
            // Non-interleaved: buffer 0 is already a single channel.
            ring.write(floats, count: totalFloats)
            return
        }

        // Interleaved multichannel — downmix to mono in place-free fashion.
        let frames = totalFloats / bufferChannels
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<bufferChannels {
                sum += floats[frame * bufferChannels + channel]
            }
            mono[frame] = sum / Float(bufferChannels)
        }
        mono.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            ring.write(base, count: frames)
        }
    }

    // MARK: - Core Audio plumbing

    private func tapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioDevices.propertyAddress(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw TapError.tapFormatUnavailable(status) }
        return asbd
    }

    private func installDefaultOutputDeviceListener() {
        var address = AudioDevices.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDefaultOutputDeviceChanged?()
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
    }

    private func removeDefaultOutputDeviceListener() {
        guard let listenerBlock else { return }
        var address = AudioDevices.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listenerBlock
        )
        self.listenerBlock = nil
    }
}
