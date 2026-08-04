import SwiftUI

struct ProcessingView: View {
    let percent: Double
    let message: String
    var processedSeconds: Double?
    var totalSeconds: Double?
    /// Absent only where there is nothing to cancel.
    var onCancel: (() -> Void)?
    @Environment(\.pikoTheme) private var theme

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(theme.accent)
                .symbolEffect(.variableColor.iterative)

            Text("Processing Video")
                .font(.title2.bold())
                .foregroundStyle(theme.text)

            // Live media position: how much of the recording is done.
            if let processed = processedSeconds, let total = totalSeconds, total > 0 {
                Text("\(clock(processed)) / \(clock(total))")
                    .font(.title3.monospacedDigit().weight(.medium))
                    .foregroundStyle(theme.dim)
                    .contentTransition(.numericText())
            }

            VStack(spacing: 8) {
                ProgressView(value: percent, total: 100)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 300)

                HStack {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(theme.dim)
                    Spacer()
                    Text("\(Int(percent))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.dim)
                }
                .frame(maxWidth: 300)
            }

            // An hour-long file used to be escapable only by quitting.
            if let onCancel {
                Button("Cancel", role: .cancel, action: onCancel)
                    .controlSize(.small)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
