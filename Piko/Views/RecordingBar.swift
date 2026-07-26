import SwiftUI

/// Record controls for the Meeting Summary screen: one big button, the elapsed
/// clock, and a live meter per track so it is obvious *before* the meeting ends
/// that both sides are actually being heard.
struct RecordingBar: View {
    @Bindable var recorder: MeetingRecorder
    let permissions: RecordingPermissions
    let onToggle: () -> Void
    let onPauseToggle: () -> Void

    @Environment(\.pikoTheme) private var theme

    var body: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    recordButton
                    clock
                    Spacer(minLength: 12)
                    sources
                    if recorder.isActive {
                        pauseButton
                    }
                }
                if let hint = statusHint {
                    hintRow(hint)
                }
            }
        }
    }

    // MARK: - Pieces

    private var recordButton: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .fill(recorder.isActive ? theme.card2 : Color.red.opacity(0.9))
                    .frame(width: 46, height: 46)
                if recorder.isActive {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.red)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.state == .starting || recorder.state == .finishing)
        .help(recorder.isActive ? "Stop and transcribe" : "Start recording")
    }

    private var clock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.clockText(recorder.elapsed))
                .font(.system(size: 21, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.text)
                .contentTransition(.numericText())
            Text(stateText)
                .font(.system(size: 11.5))
                .foregroundStyle(recorder.state == .paused ? theme.accent : theme.dim)
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 7) {
            sourceRow(
                title: "Microphone",
                icon: "mic",
                isOn: $recorder.recordMicrophone,
                level: recorder.micLevel,
                needsAttention: permissions.mic == .denied
            )
            sourceRow(
                title: "System audio",
                icon: "speaker.wave.2",
                isOn: $recorder.recordSystemAudio,
                level: recorder.systemLevel,
                needsAttention: permissions.systemAudio == .silent
            )
        }
        .frame(width: 250)
    }

    private func sourceRow(
        title: String,
        icon: String,
        isOn: Binding<Bool>,
        level: Double,
        needsAttention: Bool
    ) -> some View {
        HStack(spacing: 9) {
            Toggle(isOn: isOn) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                    Text(title)
                        .font(.system(size: 12))
                }
                .foregroundStyle(isOn.wrappedValue ? theme.text : theme.dim)
            }
            .toggleStyle(.checkbox)
            .disabled(recorder.isActive)

            Spacer(minLength: 4)

            if needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.accent)
            }
            LevelMeter(level: isOn.wrappedValue ? level : 0)
                .frame(width: 74, height: 5)
        }
    }

    private var pauseButton: some View {
        PanelToggleButton(
            icon: recorder.state == .paused ? "play.fill" : "pause.fill",
            help: recorder.state == .paused ? "Resume" : "Pause",
            action: onPauseToggle
        )
    }

    private func hintRow(_ hint: Hint) -> some View {
        HStack(spacing: 8) {
            Image(systemName: hint.icon)
                .font(.system(size: 11))
                .foregroundStyle(theme.accent)
            Text(hint.text)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let action = hint.action {
                Button(action.title, action: action.run)
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Status

    private struct Hint {
        let icon: String
        let text: String
        var action: HintAction?
    }

    private var stateText: String {
        switch recorder.state {
        case .idle: return recorder.elapsed > 0 ? "Recorded" : "Ready"
        case .starting: return "Starting..."
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .finishing: return "Finishing..."
        case .failed: return "Could not record"
        }
    }

    private var statusHint: Hint? {
        if case .failed(let message) = recorder.state {
            return Hint(
                icon: "exclamationmark.triangle",
                text: message,
                action: permissions.mic == .denied
                    ? HintAction(title: "Open Settings", run: permissions.openMicrophoneSettings)
                    : nil
            )
        }
        if let warning = recorder.warning {
            return Hint(
                icon: "exclamationmark.triangle",
                text: warning,
                action: HintAction(title: "Open Settings", run: permissions.openSystemAudioSettings)
            )
        }
        if recorder.recordSystemAudio, !recorder.isActive {
            switch permissions.systemAudio {
            case .unknown:
                return Hint(
                    icon: "info.circle",
                    text: "System audio capture needs a one-time permission. The check plays a short sound.",
                    action: HintAction(title: permissions.isProbing ? "Checking..." : "Check now") {
                        Task { await permissions.probeSystemAudio() }
                    }
                )
            case .silent:
                return Hint(
                    icon: "exclamationmark.triangle",
                    text: "The check heard nothing. Allow Piko under Privacy & Security → Audio Capture "
                        + "(and make sure the output volume is up).",
                    action: HintAction(title: "Open Settings", run: permissions.openSystemAudioSettings)
                )
            case .failed(let message):
                return Hint(icon: "exclamationmark.triangle", text: message, action: nil)
            case .unsupportedOS:
                return Hint(
                    icon: "info.circle",
                    text: "System audio capture needs macOS 14.4 or newer — recording microphone only.",
                    action: nil
                )
            case .granted:
                return nil
            }
        }
        return nil
    }

    private static func clockText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

/// One actionable suggestion attached to a recording hint.
private struct HintAction {
    let title: String
    let run: () -> Void
}

/// Peak meter for one track.
struct LevelMeter: View {
    let level: Double
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.card2)
                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(0, min(1, scaled)) * geometry.size.width)
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }

    /// Peaks are tiny in linear terms; a square-root curve makes normal speech
    /// fill a useful part of the bar.
    private var scaled: Double {
        level <= 0 ? 0 : sqrt(level)
    }
}
