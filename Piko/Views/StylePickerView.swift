import SwiftUI

struct StylePickerView: View {
    @Bindable var processor: VideoProcessorVM
    var previews: StylePreviewsVM

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
                Text("Output Folder")
                    .font(.headline)

                Text(processor.outputDirDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Button("Change…") {
                        processor.chooseOutputDir()
                    }
                    .controlSize(.small)

                    if processor.outputDirOverride != nil {
                        Button("Use Default") {
                            processor.resetOutputDir()
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }
}

extension Color {
    /// Init from "#RRGGBB".
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(h, radix: 16) ?? 0xFFD700
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
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
