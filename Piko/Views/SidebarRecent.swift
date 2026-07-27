import AppKit
import SwiftUI

/// The sidebar's Recent section — the Library's short head, in whichever of
/// the sidebar's two layouts is showing. Both verticals appear in it: a call
/// recorded five minutes ago and a video captioned yesterday are the same kind
/// of thing to the person looking for them.
struct SidebarRecent: View {
    enum Layout {
        /// Rows with a title, in the expanded sidebar.
        case list
        /// Icon-only buttons, in the collapsed rail.
        case rail
    }

    let layout: Layout
    let items: [LibraryItem]
    @Bindable var appState: AppState
    var history: HistoryStore
    var processor: VideoProcessorVM
    var meeting: MeetingVM

    @Environment(\.pikoTheme) private var theme
    /// The entry whose name is being edited, if any — rows are built by a
    /// function, so one editing state lives here rather than in each row.
    @State private var renamingID: String?

    var body: some View {
        switch layout {
        case .list:
            VStack(alignment: .leading, spacing: 1) {
                // "Loaded" state is deliberately quieter than the accent nav
                // pill — only one thing in the sidebar should read as active.
                ForEach(items.prefix(4)) { item in
                    row(item)
                }
            }
        case .rail:
            VStack(spacing: 6) {
                ForEach(items.prefix(3)) { item in
                    railButton(item)
                }
            }
        }
    }

    /// The session currently loaded on its own screen.
    private func isOpen(_ item: LibraryItem) -> Bool {
        switch item.source {
        case .meeting(let recording): meeting.selectedID == recording.id
        case .captions(let entry): processor.videoURL?.path == entry.videoPath
        }
    }

    // MARK: - Expanded row

    /// A tap anywhere in the row opens the entry; the trailing menu button
    /// intercepts its own taps first, so it never triggers the row's open.
    private func row(_ item: LibraryItem) -> some View {
        let isActive = isOpen(item)
        return HStack(spacing: 9) {
            icon(item)
            EditableTitle(
                text: item.title,
                isEditing: Binding(get: { renamingID == item.id },
                                   set: { renamingID = $0 ? item.id : nil }),
                font: .system(size: 12.5),
                color: item.isAvailable ? theme.text : theme.dim,
                onRename: { rename(item, to: $0) }
            )
            Spacer(minLength: 0)
            if isActive {
                Circle().fill(theme.accent).frame(width: 5, height: 5)
            }
            entryMenu(item)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isActive ? theme.card2 : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        // Mid-rename a click belongs to the field: navigating away would throw
        // the edit out along with the screen.
        .onTapGesture {
            guard renamingID != item.id else { return }
            open(item)
        }
        .help(item.isAvailable ? item.subtitle : "File moved or deleted")
    }

    @ViewBuilder
    private func icon(_ item: LibraryItem) -> some View {
        switch item.source {
        case .meeting:
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.card2)
                .frame(width: 24, height: 15)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 8))
                        .foregroundStyle(theme.dim)
                }
        case .captions(let entry):
            VideoThumbView(path: entry.videoPath, cornerRadius: 3)
                .frame(width: 24, height: 15)
                .opacity(entry.fileExists ? 1 : 0.4)
        }
    }

    /// Borderless "..." menu. A captions run can be forgotten from here — that
    /// only drops the history entry, the video itself is untouched. A meeting
    /// cannot: its folder *is* the recording, so deleting one lives in the
    /// Library behind a confirm rather than one slip away in the sidebar.
    private func entryMenu(_ item: LibraryItem) -> some View {
        Menu {
            Button("Rename") { renamingID = item.id }
            if let entry = item.captionsEntry {
                Button(role: .destructive) {
                    history.remove(entry)
                } label: {
                    Label("Remove from Recent", systemImage: "trash")
                }
            }
            if let url = item.revealURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11))
                .foregroundStyle(theme.dim)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Written back into the store the session came from, so the name changes
    /// everywhere at once — this list, the Library and the meeting's own screen
    /// are three views of the same record.
    private func rename(_ item: LibraryItem, to title: String) {
        switch item.source {
        case .meeting(let recording): meeting.rename(recording, to: title)
        case .captions(let entry): history.rename(entry, to: title)
        }
    }

    // MARK: - Collapsed rail

    private func railButton(_ item: LibraryItem) -> some View {
        let isActive = isOpen(item)
        return Button {
            open(item)
        } label: {
            railIcon(item)
                .frame(width: 30, height: 30)
                .background(
                    isActive ? theme.card2 : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(theme.accent)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isAvailable)
        .help(item.title)
    }

    @ViewBuilder
    private func railIcon(_ item: LibraryItem) -> some View {
        switch item.source {
        case .meeting:
            Image(systemName: "waveform")
                .font(.system(size: 12))
                .foregroundStyle(theme.dim)
        case .captions(let entry):
            VideoThumbView(path: entry.videoPath, cornerRadius: 4)
                .frame(width: 24, height: 16)
                .opacity(entry.fileExists ? 1 : 0.4)
        }
    }

    // MARK: - Opening

    /// Reopen a session on its own screen. Transcription is cached by the
    /// backend, so a captions rerun is fast; clicking the entry that is
    /// already open just navigates without restarting anything.
    private func open(_ item: LibraryItem) {
        switch item.source {
        case .meeting(let recording):
            meeting.select(recording)
            appState.screen = .summary
        case .captions(let entry):
            guard entry.fileExists else { return }
            appState.screen = .captions
            guard processor.videoURL?.path != entry.videoPath else { return }
            processor.reset()
            processor.videoURL = URL(fileURLWithPath: entry.videoPath)
        }
    }
}
