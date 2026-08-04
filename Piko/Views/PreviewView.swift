import SwiftUI
import AVKit

/// AVPlayerView wrapper: unlike SwiftUI's VideoPlayer it shows the
/// full-screen toggle in the inline controls.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

struct PreviewView: View {
    @Bindable var processor: VideoProcessorVM
    let onReset: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 16) {
            // Video player — flexible height, full screen via its toggle.
            // Style switching lives in the settings panel; it re-renders
            // instantly from the cached transcription.
            if let player {
                PlayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // Stats
            HStack(spacing: 24) {
                StatBadge(icon: "globe", label: "Language",
                          value: processor.detectedLanguage?.uppercased() ?? "—")
                StatBadge(icon: "text.word.spacing", label: "Words",
                          value: "\(processor.wordCount)")
                StatBadge(icon: "star.fill", label: "Keywords",
                          value: "\(processor.keywordsFound)")
                if let rtf = processor.realtimeFactor {
                    StatBadge(icon: "speedometer", label: "Realtime",
                              value: String(format: "%.1f×", rtf))
                }
                if let wps = processor.wordsPerSecond {
                    StatBadge(icon: "gauge.with.dots.needle.67percent", label: "Words/s",
                              value: String(format: "%.1f", wps))
                }
            }

            runTimeline

            // Saving lives in the screen header (Save Video… / Save .srt…);
            // the render stays in the app cache until then.
            HStack(spacing: 10) {
                // Back to the words without redoing anything — a wrong name
                // is usually spotted here, watching the burned result.
                if processor.hasTranscript {
                    Button("Back to Transcript") { processor.showTranscript() }
                }
                Button("Process Another") { onReset() }
            }
            .padding(.bottom)
        }
        .onAppear {
            if let url = processor.outputURL {
                player = AVPlayer(url: url)
            }
        }
        .onChange(of: processor.outputURL) { _, newURL in
            player?.pause()
            player = newURL.map { AVPlayer(url: $0) }
        }
    }

    /// "Started 14:03:21 → finished 14:03:58 · 37 s" for the last full run.
    @ViewBuilder
    private var runTimeline: some View {
        if let started = processor.runStartedAt,
           let finished = processor.runFinishedAt,
           let seconds = processor.processingSeconds {
            let begin = started.formatted(.dateTime.hour().minute().second())
            let end = finished.formatted(.dateTime.hour().minute().second())
            Text("Started \(begin) → finished \(end) · \(String(format: "%.1f", seconds)) s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct StatBadge: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 80)
    }
}
