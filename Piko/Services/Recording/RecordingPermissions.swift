import AppKit
import AVFoundation
import Foundation

/// The two grants a meeting recording needs, and the only honest way to check
/// them.
///
/// Microphone has a real API (`AVCaptureDevice.authorizationStatus`). System
/// audio does not: Core Audio has no public preflight, and a tap created
/// without the grant still "succeeds" — it just delivers silence forever. So
/// the check here is empirical: start a tap, play a short system sound, and see
/// whether the tap heard it. That also doubles as the prompt trigger, since
/// macOS raises the Audio Capture dialog on first tap creation.
@MainActor
@Observable
final class RecordingPermissions {
    enum MicAccess: Equatable {
        case granted
        case notDetermined
        case denied
    }

    enum SystemAudioAccess: Equatable {
        case unknown
        case granted
        /// Tap ran but heard nothing — either the grant is missing or nothing
        /// was playing / output is muted.
        case silent
        case unsupportedOS
        case failed(String)
    }

    private(set) var mic: MicAccess = .notDetermined
    private(set) var systemAudio: SystemAudioAccess = .unknown
    private(set) var isProbing = false

    init() {
        refreshMic()
        if #unavailable(macOS 14.2) {
            systemAudio = .unsupportedOS
        }
    }

    // MARK: - Microphone

    func refreshMic() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .granted
        case .notDetermined: mic = .notDetermined
        default: mic = .denied
        }
    }

    /// Triggers the system prompt the first time; afterwards it only reports.
    @discardableResult
    func requestMic() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refreshMic()
        return granted
    }

    // MARK: - System audio

    /// Creates a tap, plays a short sound, and reports whether the tap heard
    /// it. First run also raises the Audio Capture permission dialog.
    func probeSystemAudio() async {
        guard #available(macOS 14.2, *) else {
            systemAudio = .unsupportedOS
            return
        }
        guard !isProbing else { return }
        isProbing = true
        defer { isProbing = false }

        let tap = SystemAudioTap()
        do {
            try tap.start()
        } catch {
            systemAudio = .failed(error.localizedDescription)
            return
        }
        defer { tap.stop() }

        // Give the tap a moment, then make noise on purpose: without a signal
        // "silence" would be indistinguishable from "denied".
        try? await Task.sleep(for: .milliseconds(300))
        _ = tap.buffer.drain()
        NSSound(named: "Ping")?.play()

        var peak: Float = 0
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(100))
            for sample in tap.buffer.drain() {
                peak = max(peak, abs(sample))
            }
            if peak > 0.0005 { break }
        }
        systemAudio = peak > 0.0005 ? .granted : .silent
    }

    // MARK: - System Settings deep links

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openSystemAudioSettings() {
        // The Audio Capture pane has no documented anchor; the Privacy root is
        // the reliable landing spot, and the row sits right under Microphone.
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
