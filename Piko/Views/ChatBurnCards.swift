import AVKit
import SwiftUI

// The burn, in the thread.
//
// This was the last step that still threw the reader onto another screen, and
// it was the least defensible one: picking a look and watching it render is
// exactly the kind of thing a conversation can hold. What lives here is the
// whole loop — choose, burn, watch, save — so the thread never hands off.

/// Pick a look, then spend the re-encode.
///
/// The button is worded as what it costs rather than what it does: this is the
/// one action in the app that rewrites the whole video, and every other export
/// on the previous card was free.
struct ChatStyleCard: View {
    @Bindable var processor: VideoProcessorVM
    var previews: StylePreviewsVM
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 9) {
                    SectionLabel(text: "Style")
                    Text("re-encodes the video · everything else was free")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                    Spacer()
                    Button(processor.outputURL == nil ? "Burn it in" : "Burn again") {
                        processor.burn()
                    }
                    .buttonStyle(AccentButtonStyle())
                    .controlSize(.small)
                    .disabled(processor.isProcessing)
                }

                HStack(spacing: 7) {
                    ForEach(SubtitleStyleType.allCases) { style in
                        styleTile(style)
                    }
                }

                wordModeRow
            }
        }
    }

    private func styleTile(_ style: SubtitleStyleType) -> some View {
        let isOn = processor.selectedStyle == style
        return Button {
            processor.selectedStyle = style
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Group {
                    if let preview = previews.image(for: style) {
                        Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        theme.card2
                    }
                }
                .frame(height: 36)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                Text(style.displayName)
                    .font(.system(size: 11, weight: isOn ? .medium : .regular))
                    .foregroundStyle(isOn ? theme.text : theme.dim)
                    .padding(.leading, 1)
            }
            .padding(5)
            .background(isOn ? theme.card2 : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(isOn ? theme.accent : theme.line)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Two styles animate words themselves and ignore the setting, so the
    /// control is dimmed for them rather than quietly doing nothing.
    @ViewBuilder
    private var wordModeRow: some View {
        let supported = processor.selectedStyle.supportsWordMode
        HStack(spacing: 9) {
            Picker("", selection: $processor.wordMode) {
                ForEach(WordMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .disabled(!supported)
            .opacity(supported ? 1 : 0.45)
            .help(supported
                  ? processor.wordMode.help
                  : "\(processor.selectedStyle.displayName) animates words on its own")

            if supported, processor.wordMode == .highlight {
                ForEach(highlightPalette, id: \.hex) { swatch in
                    Button {
                        processor.highlightColorHex = swatch.hex
                    } label: {
                        Circle()
                            .fill(Color(hex: swatch.hex))
                            .frame(width: 15, height: 15)
                            .overlay {
                                Circle().strokeBorder(
                                    processor.highlightColorHex == swatch.hex
                                        ? theme.text : .clear,
                                    lineWidth: 2
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                }
            }
            Spacer()
        }
    }
}

/// The re-encode itself: one bar, one clock, one way out.
struct ChatBurnProgressCard: View {
    @Bindable var processor: VideoProcessorVM
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    SectionLabel(text: "Burning")
                    Text(clockLine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.dim)
                    Spacer()
                    Text("\(Int(processor.progressPercent))%")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.accent)
                }
                ProgressView(value: min(max(processor.progressPercent, 0), 100), total: 100)
                    .progressViewStyle(.linear)
                HStack {
                    Text(processor.progressMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel") { processor.cancel() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var clockLine: String {
        guard let total = processor.totalMediaSeconds, total > 0 else { return "" }
        let done = processor.processedMediaSeconds ?? 0
        return "\(clock(done)) / \(clock(total))"
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// The finished video, playable where it was asked for.
struct ChatResultCard: View {
    @Bindable var processor: VideoProcessorVM
    @State private var player: AVPlayer?
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    SectionLabel(text: "Result")
                    Text(stats)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                    Spacer()
                    Button("Save Video…") { processor.saveVideo() }
                        .buttonStyle(AccentButtonStyle())
                        .controlSize(.small)
                }

                if let player {
                    VideoPlayer(player: player)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Text("The render lives in the app cache until you save it — nothing is "
                     + "written next to your original.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dim)
            }
        }
        .onAppear { rebuild(processor.outputURL) }
        .onChange(of: processor.outputURL) { _, url in rebuild(url) }
    }

    private var stats: String {
        var parts = [processor.selectedStyle.displayName]
        if let rtf = processor.realtimeFactor {
            parts.append(String(format: "%.1f× realtime", rtf))
        }
        return parts.joined(separator: " · ")
    }

    private func rebuild(_ url: URL?) {
        player?.pause()
        player = url.map(AVPlayer.init(url:))
    }
}
