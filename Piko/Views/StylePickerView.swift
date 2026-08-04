import AppKit
import SwiftUI

/// Caption settings panel content: style tiles, word animation and storage.
/// Styled after the mockup's "Template" panel — accent border marks the
/// selected tile, no system list chrome.
struct StylePickerView: View {
    @Bindable var processor: VideoProcessorVM
    var previews: StylePreviewsVM
    @Environment(\.pikoTheme) private var theme

    @State private var showClearConfirm = false
    @State private var cacheSize = "…"
    @State private var pack = BRollPackVM()
    @State private var fetchConcept = ""
    @State private var fetchQuery = ""

    private var supportsWordMode: Bool { processor.selectedStyle.supportsWordMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 6) {
                ForEach(SubtitleStyleType.allCases) { style in
                    styleTile(style)
                }
            }

            hairline

            wordAnimationSection

            hairline

            brollSection

            hairline

            storageSection
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

    private var hairline: some View {
        Rectangle().fill(theme.line).frame(height: 1)
    }

    // MARK: - Style tiles

    private func styleTile(_ style: SubtitleStyleType) -> some View {
        let isOn = processor.selectedStyle == style
        return Button {
            processor.selectedStyle = style
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                previewPlate(for: style)
                Text(style.displayName)
                    .font(.system(size: 11.5, weight: isOn ? .medium : .regular))
                    .foregroundStyle(isOn ? theme.text : theme.dim)
                    .padding(.leading, 2)
            }
            .padding(6)
            .background(isOn ? theme.card2 : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isOn ? theme.accent : theme.line)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func previewPlate(for style: SubtitleStyleType) -> some View {
        Group {
            if let preview = previews.image(for: style) {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                theme.card2
            }
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Word animation

    private var wordAnimationSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "Word animation")

            wordModeSegment
                .disabled(!supportsWordMode)
                .opacity(supportsWordMode ? 1 : 0.45)

            Text(supportsWordMode
                 ? processor.wordMode.help
                 : "\(processor.selectedStyle.displayName) has built-in word animation")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)

            if supportsWordMode && processor.wordMode == .highlight {
                highlightPaletteRow
            }
        }
    }

    private var wordModeSegment: some View {
        HStack(spacing: 0) {
            ForEach(WordMode.allCases) { mode in
                let isOn = processor.wordMode == mode
                Button {
                    processor.wordMode = mode
                } label: {
                    Text(mode.displayName)
                        .font(.system(size: 11.5, weight: isOn ? .medium : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(isOn ? theme.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(isOn ? theme.accentOn : theme.dim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.card2, in: RoundedRectangle(cornerRadius: 8))
    }

    private var highlightPaletteRow: some View {
        HStack(spacing: 8) {
            ForEach(highlightPalette, id: \.hex) { entry in
                Circle()
                    .fill(Color(hex: entry.hex))
                    .frame(width: 20, height: 20)
                    .overlay {
                        Circle().strokeBorder(
                            processor.highlightColorHex == entry.hex
                                ? theme.accent : Color.clear,
                            lineWidth: 2
                        )
                    }
                    .onTapGesture {
                        processor.highlightColorHex = entry.hex
                    }
                    .help(entry.name)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - B-roll

    private static let brollFolder = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Piko/BRoll", isDirectory: true)

    private var brollSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "B-roll")
                Spacer()
                Toggle("", isOn: $processor.brollEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .tint(theme.accent)
            }

            Text("Cut-ins from your local clip library. Folders are English concepts "
                 + "(e.g. \"dog\") matched in EN/RU/DE/FR; drop clips inside, add "
                 + "aliases.txt for extra keywords.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)

            if processor.brollEnabled, case .done = processor.state {
                Button("Regenerate with Current Clips") {
                    processor.forceRerender()
                }
                .controlSize(.small)
                .disabled(processor.isProcessing)
                .help("Re-run this render from scratch — picks up clips you've "
                      + "added or changed since the last render.")
            }

            HStack(spacing: 7) {
                Button("Reveal Library in Finder") {
                    try? FileManager.default.createDirectory(
                        at: Self.brollFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Self.brollFolder)
                }
                .controlSize(.small)

                Button("Get Starter Pack") {
                    Task { await pack.downloadPack() }
                }
                .controlSize(.small)
                .disabled(pack.isDownloading)
            }

            // Keyless Wikimedia search: keyword names the folder, the search
            // query (EN works best on Commons) finds openly licensed clips.
            // Picking a result downloads it and records its license.
            HStack(spacing: 6) {
                TextField("Keyword (any language)", text: $fetchConcept)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                TextField("Search (EN)", text: $fetchQuery)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Button("Search") {
                    let query = trimmedQuery.isEmpty ? trimmedConcept : trimmedQuery
                    Task { await pack.search(query: query) }
                }
                .controlSize(.small)
                .disabled(pack.isDownloading || (trimmedConcept.isEmpty && trimmedQuery.isEmpty))
            }
            Text("Searches Wikimedia Commons — CC0 / Public Domain / CC BY only, license is saved automatically.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.dim)

            ForEach(pack.searchResults) { clip in
                searchResultRow(clip)
            }

            if !pack.statusMessage.isEmpty {
                HStack(spacing: 6) {
                    if pack.isDownloading {
                        ProgressView().controlSize(.mini)
                    }
                    Text(pack.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                        .lineLimit(2)
                }
            }
        }
    }

    private var trimmedConcept: String {
        fetchConcept.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedQuery: String {
        fetchQuery.trimmingCharacters(in: .whitespaces)
    }

    private func searchResultRow(_ clip: BrollClip) -> some View {
        HStack(spacing: 7) {
            AsyncImage(url: clip.thumb.flatMap(URL.init(string:))) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    theme.card2
                    Image(systemName: "film")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.dim)
                }
            }
            .frame(width: 44, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 1) {
                Text(clip.title)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(clip.license) · \(Int(clip.sizeMb ?? 0)) MB")
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.dim)
            }
            Spacer(minLength: 4)
            Button {
                let concept = trimmedConcept.isEmpty ? trimmedQuery : trimmedConcept
                Task { await pack.download(clip: clip, concept: concept) }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(pack.isDownloading)
            .help("Download into \"\(trimmedConcept.isEmpty ? trimmedQuery : trimmedConcept)\"")
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .background(theme.card2.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Storage

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Storage")

            Text("Results stay in the app cache until you press Save.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)

            Button("Clear Cache (\(cacheSize))…") {
                showClearConfirm = true
            }
            .controlSize(.small)
            .disabled(processor.isProcessing)
        }
    }
}
