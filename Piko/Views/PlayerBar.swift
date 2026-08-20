import SwiftUI

/// One line: play, where you are, how long it is, and a bar you can drag.
///
/// Deliberately not a media player. There is no rate control, no skip buttons
/// and no waveform, because the way you navigate this recording is by clicking
/// a timecode in the text — the transcript *is* the scrubber, and a second
/// navigation system competing with it would only be in the way. The bar exists
/// so you can tell roughly where you are and get out of a wrong jump.
struct PlayerBar: View {
    @Bindable var player: ArtifactPlayer
    @Environment(\.pikoTheme) private var theme
    @State private var isScrubbing = false
    @State private var scrubTarget: Double = 0

    var body: some View {
        HStack(spacing: 11) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accentOn)
                    .frame(width: 28, height: 28)
                    .background { Circle().fill(theme.accent) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Text(clock(isScrubbing ? scrubTarget : player.current))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.text)
                .frame(width: 44, alignment: .leading)

            track

            Text(clock(player.duration))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.dim)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 12))
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.card2)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.line)
                }
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let fraction = player.duration > 0
                ? min(max((isScrubbing ? scrubTarget : player.current) / player.duration, 0), 1)
                : 0
            ZStack(alignment: .leading) {
                Capsule().fill(theme.line)
                Capsule().fill(theme.accent).frame(width: geo.size.width * fraction)
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard player.duration > 0 else { return }
                        isScrubbing = true
                        let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                        scrubTarget = ratio * player.duration
                    }
                    .onEnded { _ in
                        guard isScrubbing else { return }
                        player.scrub(to: scrubTarget)
                        isScrubbing = false
                    }
            )
        }
        .frame(height: 20)
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
