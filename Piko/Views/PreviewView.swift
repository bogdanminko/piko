import SwiftUI
import AVKit

struct PreviewView: View {
    @Bindable var processor: VideoProcessorVM
    var stylePreviews: StylePreviewsVM
    let onReset: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 16) {
            // Video player
            if let player {
                VideoPlayer(player: player)
                    .frame(maxHeight: 380)
                    .cornerRadius(12)
                    .padding(.horizontal)
            }

            // Style switcher — re-renders instantly from the cached
            // transcription, no new Whisper run.
            HStack(spacing: 8) {
                ForEach(SubtitleStyleType.allCases) { style in
                    StyleSwitchButton(
                        style: style,
                        isSelected: processor.selectedStyle == style,
                        preview: stylePreviews.image(for: style)
                    ) {
                        processor.selectedStyle = style
                    }
                }
            }
            .padding(.horizontal)

            // Stats
            HStack(spacing: 24) {
                StatBadge(icon: "globe", label: "Language",
                          value: processor.detectedLanguage?.uppercased() ?? "—")
                StatBadge(icon: "text.word.spacing", label: "Words",
                          value: "\(processor.wordCount)")
                StatBadge(icon: "star.fill", label: "Keywords",
                          value: "\(processor.keywordsFound)")
            }

            // Actions
            HStack(spacing: 12) {
                Button("Show in Finder") {
                    if let url = processor.outputURL {
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                    }
                }

                if let subtitleURL = processor.subtitleURL {
                    Button("Open .ass File") {
                        NSWorkspace.shared.open(subtitleURL)
                    }
                }

                Button("Process Another") {
                    onReset()
                }
                .buttonStyle(.borderedProminent)
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
}

struct StyleSwitchButton: View {
    let style: SubtitleStyleType
    let isSelected: Bool
    let preview: NSImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(style.displayName)
                    .font(.caption2.weight(isSelected ? .bold : .regular))
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
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
