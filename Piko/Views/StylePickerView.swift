import SwiftUI

struct StylePickerView: View {
    @Bindable var processor: VideoProcessorVM
    var previews: StylePreviewsVM

    @State private var showClearConfirm = false
    @State private var cacheSize = "…"

    /// TikTok and Karaoke animate words themselves; word modes only
    /// apply to the line-based styles.
    private var supportsWordMode: Bool {
        ![.tiktok, .karaoke].contains(processor.selectedStyle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Style")
                .font(.headline)
                .padding(.horizontal)

            List(SubtitleStyleType.allCases) { style in
                StyleCard(
                    style: style,
                    isSelected: processor.selectedStyle == style,
                    preview: previews.image(for: style)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    processor.selectedStyle = style
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Word Animation")
                    .font(.headline)

                Picker("", selection: $processor.wordMode) {
                    ForEach(WordMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!supportsWordMode)

                if !supportsWordMode {
                    Text("\(processor.selectedStyle.displayName) has built-in word animation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(processor.wordMode.help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if supportsWordMode && processor.wordMode == .highlight {
                    HStack(spacing: 8) {
                        ForEach(highlightPalette, id: \.hex) { entry in
                            Circle()
                                .fill(Color(hex: entry.hex))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().strokeBorder(
                                        processor.highlightColorHex == entry.hex
                                            ? Color.primary : Color.clear,
                                        lineWidth: 2
                                    )
                                )
                                .onTapGesture {
                                    processor.highlightColorHex = entry.hex
                                }
                                .help(entry.name)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Storage")
                    .font(.headline)

                Text("Results stay in the app cache until you press Save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear Cache (\(cacheSize))…") {
                    showClearConfirm = true
                }
                .controlSize(.small)
                .disabled(processor.isProcessing)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .onAppear {
            cacheSize = VideoProcessorVM.cacheSizeDescription()
        }
        .alert("Clear the app cache?", isPresented: $showClearConfirm) {
            Button("Clear Everything", role: .destructive) {
                processor.clearCache()
                cacheSize = VideoProcessorVM.cacheSizeDescription()
                // Preview strips were cached too — regenerate them.
                Task { await previews.load() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all cached transcriptions, rendered videos, and previews. Unsaved results will be lost.")
        }
    }
}

extension Color {
    /// Init from "#RRGGBB".
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let rgb = UInt64(digits, radix: 16) ?? 0xFFD700
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

struct StyleCard: View {
    let style: SubtitleStyleType
    let isSelected: Bool
    let preview: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.clear,
                                lineWidth: 2
                            )
                    )
            }

            HStack(spacing: 6) {
                if preview == nil {
                    Image(systemName: style.iconName)
                        .font(.body)
                        .foregroundStyle(style.accentColor)
                }

                Text(style.displayName)
                    .font(.system(.body, weight: isSelected ? .bold : .medium))

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
