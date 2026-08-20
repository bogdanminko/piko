import AppKit
import SwiftUI

/// Every session Piko has on disk, in one list: meetings (recorded or
/// imported) and captions runs. It reads the two stores that already exist —
/// `MeetingLibrary` and `HistoryStore` — so a call recorded on the Meeting
/// Summary screen is history here the moment it is saved, with no third copy
/// to keep in sync.
struct LibraryView: View {
    let workspace: Workspace
    var history: HistoryStore

    private var appState: AppState { workspace.appState }
    private var meeting: MeetingVM { workspace.meeting }

    @Environment(\.pikoTheme) private var theme
    @State private var query = ""
    @State private var filter: Filter = .all
    /// Deleting a meeting destroys audio the user cannot get back, so it is the
    /// one row action that asks first.
    @State private var pendingDeletion: LibraryItem?
    @State private var recordingsSize: Int64 = 0

    enum Filter: String, CaseIterable, Identifiable {
        case all, meetings, captions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .meetings: "Meetings"
            case .captions: "Captions"
            }
        }
    }

    // MARK: - Data

    private var allItems: [LibraryItem] {
        LibraryItem.all(meetings: meeting.recordings, captions: history.entries)
    }

    private func matches(_ item: LibraryItem, _ filter: Filter) -> Bool {
        switch filter {
        case .all: true
        case .meetings: item.recording != nil
        case .captions: item.captionsEntry != nil
        }
    }

    private var visibleItems: [LibraryItem] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        return allItems.filter { item in
            guard matches(item, filter) else { return false }
            guard !text.isEmpty else { return true }
            return item.title.lowercased().contains(text)
                || item.subtitle.lowercased().contains(text)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: "Library",
                         subtitle: "Every session Piko has on disk") {
                searchField
            }
            if allItems.isEmpty {
                emptyState
                Spacer(minLength: 0)
            } else {
                filterRow
                sessionList
                footer
            }
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
        // Recordings made in this session's Meeting Summary screen are already
        // in the VM; a rescan also catches a folder deleted from outside.
        .onAppear {
            meeting.refresh()
            recordingsSize = meeting.recordings.reduce(0) { $0 + MeetingLibrary.sizeOnDisk($1) }
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { item in
            Button("Delete", role: .destructive) { confirmDeletion(item) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { item in
            Text("“\(item.title)” — audio, transcript and summary — is removed from disk. "
                 + "This cannot be undone.")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.dim)
            TextField("Search sessions", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .frame(width: 220)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line))
    }

    // MARK: - Filters

    private var filterRow: some View {
        HStack(spacing: 7) {
            ForEach(Filter.allCases) { value in
                filterChip(value)
            }
            Spacer(minLength: 0)
        }
    }

    private func filterChip(_ value: Filter) -> some View {
        let isActive = filter == value
        let count = allItems.filter { matches($0, value) }.count
        return Button {
            filter = value
        } label: {
            HStack(spacing: 6) {
                Text(value.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? theme.text : theme.dim)
                Text("\(count)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.dim)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(isActive ? theme.card2 : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(isActive ? theme.accent : theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    @ViewBuilder
    private var sessionList: some View {
        if visibleItems.isEmpty {
            noMatchesState
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    ForEach(LibraryItem.byDay(visibleItems)) { day in
                        daySection(day)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func daySection(_ day: LibraryDay) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: day.title)
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(day.items) { item in
                    LibraryRow(item: item,
                               isOpen: isOpen(item),
                               onOpen: { open(item) },
                               onExportMarkdown: { exportMarkdown(item) },
                               onRename: { rename(item, to: $0) },
                               onDelete: { delete(item) })
                    if item.id != day.items.last?.id {
                        Rectangle().fill(theme.line).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .cardSurface(theme)
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 9) {
                Text("Nothing here yet.")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("Record a call or drop any file with speech in it — every "
                     + "session lands here with its transcript, and reopens "
                     + "from this list.")
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(theme.dim)
                Button("Open the workspace") { appState.screen = .artifact }
                    .buttonStyle(AccentButtonStyle())
                    .padding(.top, 4)
            }
        }
    }

    private var noMatchesState: some View {
        Text(query.isEmpty
             ? "No \(filter.title.lowercased()) yet."
             : "Nothing matches “\(query)”.")
            .font(.system(size: 12.5))
            .foregroundStyle(theme.dim)
            .padding(.vertical, 22)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footerText)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
            Spacer(minLength: 0)
            if FileManager.default.fileExists(atPath: MeetingLibrary.root.path) {
                Button("Show Recordings in Finder") {
                    NSWorkspace.shared.open(MeetingLibrary.root)
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }

    private var footerText: String {
        let sessions = allItems.count
        var text = "\(sessions) session\(sessions == 1 ? "" : "s")"
        if recordingsSize > 0 {
            let size = ByteCountFormatter.string(fromByteCount: recordingsSize, countStyle: .file)
            text += " · \(size) of recordings in Application Support"
        }
        return text
    }

    // MARK: - Actions

    /// The session currently loaded on its own screen.
    private func isOpen(_ item: LibraryItem) -> Bool {
        switch item.source {
        // "Open" now means "some conversation is about it", which is the only
        // reading that survives having more than one.
        case .meeting(let recording):
            workspace.store.session(holdingMeeting: recording.id) != nil
        case .captions(let entry):
            workspace.store.session(holdingVideo: URL(fileURLWithPath: entry.videoPath)) != nil
        }
    }

    /// Meetings reopen on the summary screen, captions runs on Captions.
    /// Clicking the one that is already open only navigates — nothing is
    /// reprocessed.
    private func open(_ item: LibraryItem) {
        ArtifactRouting.open(item, into: workspace)
    }

    /// The title is the one thing on a row a person owns; the rest is read off
    /// disk. It is written back into whichever store the session came from —
    /// meta.json for a meeting, history.json for a captions run — so the
    /// sidebar's Recent and the Meeting Summary screen show it as well.
    private func rename(_ item: LibraryItem, to title: String) {
        switch item.source {
        case .meeting(let recording): meeting.rename(recording, to: title)
        case .captions(let entry): history.rename(entry, to: title)
        }
    }

    /// Same file the summary screen exports: the generated summary with the
    /// user's edits composed on top, never the raw one.
    private func exportMarkdown(_ item: LibraryItem) {
        guard let recording = item.recording,
              let summary = MeetingLibrary.loadSummary(for: recording) else { return }
        let composed = ComposedSummary.make(summary, edits: MeetingLibrary.loadEdits(for: recording))
        let notes = MeetingLibrary.loadNotes(for: recording.id)
        MarkdownExport.save(MarkdownExport.make(composed, for: recording, notes: notes.notes),
                            suggestedName: recording.title)
    }

    /// Dropping a captions entry only forgets the run — the video it points at
    /// is the user's own file and is never touched. A meeting is the opposite:
    /// its folder *is* the material, so it goes through the confirm dialog.
    private func delete(_ item: LibraryItem) {
        if let entry = item.captionsEntry {
            history.remove(entry)
        } else {
            pendingDeletion = item
        }
    }

    private func confirmDeletion(_ item: LibraryItem) {
        pendingDeletion = nil
        guard let recording = item.recording else { return }
        meeting.delete(recording)
        recordingsSize = meeting.recordings.reduce(0) { $0 + MeetingLibrary.sizeOnDisk($1) }
    }
}
