import CoreAudio
import Foundation

/// Thin wrapper over the Core Audio property calls both captures need.
///
/// CFString properties come back +1 through a raw pointer, so they go through
/// `Unmanaged` — passing a `CFString` variable by reference compiles but leaks
/// the reference-counting semantics (and warns).
enum AudioDevices {
    static func defaultOutputDevice() -> AudioObjectID? {
        device(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultInputDevice() -> AudioObjectID? {
        device(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    static func name(of deviceID: AudioObjectID) -> String? {
        string(deviceID, selector: kAudioObjectPropertyName)
    }

    static func uid(of deviceID: AudioObjectID) -> String? {
        string(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func device(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = propertyAddress(selector)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private static func string(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
