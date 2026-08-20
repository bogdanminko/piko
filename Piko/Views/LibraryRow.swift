import AppKit
import SwiftUI

/// One session line in the Library. Both verticals render through it, so a
/// meeting and a captions run read as the same kind of record — only the
/// leading tile and the stage badge differ.
struct LibraryRow: View {
    let item: LibraryItem
    /// The session currently loaded on its own screen.
    let isOpen: Bool
    let onOpen: () -> Void
    let onExportMarkdown: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @Environment(\.pikoTheme) private var theme
    /// Local: the row is the only thing that needs to know it is being renamed,
    /// and the list rebuilds around it without disturbing the field.
    @State private var isRenaming = false

    /// A tap anywhere opens the session; the trailing menu intercepts its own
    /// taps first, so it never triggers the row's open.
    var body: some View {
        HStack(spacing: 11) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                EditableTitle(text: item.title,
                              isEditing: $isRenaming,
                              font: .system(size: 13),
                              color: item.isAvailable ? theme.text : theme.dim,
                              onRename: onRename)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let durationText = item.durationText {
                Timecode(text: durationText)
            }
            statusChip
                .frame(width: 132, alignment: .trailing)
            Text(item.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11))
                .foregroundStyle(theme.dim)
                .frame(width: 62, alignment: .trailing)
            // Quieter than the sidebar's accent pill: only one thing in the
            // window should read as active.
            Circle()
                .fill(isOpen ? theme.accent : .clear)
                .frame(width: 5, height: 5)
            menu
        }
        .padding(.vertical, 9)
        .background(isOpen ? theme.card2.opacity(0.6) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        // A click while the name is being edited belongs to the field, not to
        // the row: opening the session mid-rename would throw the edit away.
        .onTapGesture { if !isRenaming { onOpen() } }
        .help(item.isAvailable ? item.subtitle : "File moved or deleted")
    }

    /// Both kinds share one 44×28 slot so the titles line up: a video keeps
    /// its frame, a meeting gets a waveform tile.
    @ViewBuilder
    private var thumbnail: some View {
        switch item.source {
        case .meeting:
            RoundedRectangle(cornerRadius: 5)
                .fill(theme.card2)
                .frame(width: 44, height: 28)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.dim)
                }
        case .captions(let entry):
            VideoThumbView(path: entry.videoPath, cornerRadius: 5)
                .frame(width: 44, height: 28)
                .opacity(entry.fileExists ? 1 : 0.4)
        }
    }

    private var statusChip: some View {
        Text(item.stage.label)
            .font(.system(size: 11.5))
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(item.stage.isComplete ? theme.positive : theme.dim)
            .lineLimit(1)
    }

    private var menu: some View {
        RowMenuButton {
            Button("Open", action: onOpen)
                .disabled(!item.isAvailable)
            Button("Rename") { isRenaming = true }
            if item.recording != nil, item.hasSummary {
                Button("Export Markdown…", action: onExportMarkdown)
            }
            if let url = item.revealURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label(item.recording == nil ? "Remove from Library" : "Delete Recording…",
                      systemImage: "trash")
            }
        }
    }
}
