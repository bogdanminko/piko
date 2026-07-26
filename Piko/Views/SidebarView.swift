import SwiftUI

/// Fixed navigation sidebar from the design mockup: Workspace / Recent /
/// System sections plus the embedded-model card at the bottom. Collapses
/// into an icon-only rail.
struct SidebarView: View {
    @Bindable var appState: AppState
    var modelManager: ModelManagerVM
    var history: HistoryStore
    var processor: VideoProcessorVM
    @Environment(\.pikoTheme) private var theme

    private static let icons: [AppScreen: String] = [
        .library: "square.grid.2x2",
        .summary: "waveform.circle",
        .captions: "captions.bubble",
        .models: "cpu",
        .appearance: "paintpalette"
    ]

    var body: some View {
        Group {
            if appState.sidebarCollapsed {
                rail
            } else {
                full
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func icon(for screen: AppScreen) -> String {
        Self.icons[screen] ?? "questionmark"
    }

    /// The real app icon (bundle plist or the bare-run dock icon set by
    /// AppDelegate) — same asset everywhere.
    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
    }

    private var toggleButton: some View {
        PanelToggleButton(
            icon: appState.sidebarCollapsed ? "sidebar.leading" : "sidebar.left",
            help: appState.sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"
        ) {
            withAnimation(.easeInOut(duration: 0.18)) {
                appState.sidebarCollapsed.toggle()
            }
        }
    }

    // MARK: - Expanded

    /// Height of the traffic-light strip both layouts reserve, so the
    /// toggle button and everything below sit at identical y in both.
    private static let brandStripHeight: CGFloat = 32

    private var full: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Brand row lives in the traffic-light strip (leading inset
            // clears the window buttons).
            HStack(spacing: 8) {
                appIcon
                    .frame(width: 24, height: 24)
                Text("Piko")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
            }
            .padding(.leading, 68)
            .frame(height: Self.brandStripHeight, alignment: .top)

            toggleButton
                .padding(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 0))

            SectionLabel(text: "Workspace")
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 5, trailing: 10))

            navButton(.library)
            navButton(.summary)
            navButton(.captions)

            SectionLabel(text: "Recent")
                .padding(EdgeInsets(top: 16, leading: 10, bottom: 5, trailing: 10))
            if history.entries.isEmpty {
                recentPlaceholder
            } else {
                recentEntries
            }

            SectionLabel(text: "System")
                .padding(EdgeInsets(top: 16, leading: 10, bottom: 5, trailing: 10))
            navButton(.models)
            navButton(.appearance)

            Spacer(minLength: 12)
            modelCard
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 12, trailing: 10))
        .frame(width: 224)
    }

    private func navButton(_ screen: AppScreen) -> some View {
        let isActive = appState.screen == screen
        return Button {
            appState.screen = screen
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon(for: screen))
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(screen.title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isActive ? theme.accent : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .foregroundStyle(isActive ? theme.accentOn : theme.text)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The entry whose video is currently open on the Captions screen.
    private func isOpen(_ entry: HistoryEntry) -> Bool {
        processor.videoURL?.path == entry.videoPath
    }

    private var recentEntries: some View {
        VStack(alignment: .leading, spacing: 1) {
            // "Loaded" state is deliberately quieter than the accent nav
            // pill — only one thing in the sidebar should read as active.
            ForEach(history.entries.prefix(4)) { entry in
                let isMissing = !entry.fileExists
                let isActive = isOpen(entry)
                Button {
                    openEntry(entry)
                } label: {
                    HStack(spacing: 9) {
                        VideoThumbView(path: entry.videoPath, cornerRadius: 3)
                            .frame(width: 24, height: 15)
                            .opacity(isMissing ? 0.4 : 1)
                        Text(entry.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(isMissing ? theme.dim : theme.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        if isActive {
                            Circle().fill(theme.accent).frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isActive ? theme.card2 : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isMissing)
                .help(isMissing ? "File moved or deleted" : entry.videoPath)
            }
        }
    }

    /// Reopen a processed video on the Captions screen. Transcription is
    /// cached by the backend, so the run is fast. Clicking the entry that
    /// is already open just navigates without restarting the pipeline.
    private func openEntry(_ entry: HistoryEntry) {
        appState.screen = .captions
        guard !isOpen(entry) else { return }
        processor.reset()
        processor.videoURL = URL(fileURLWithPath: entry.videoPath)
    }

    /// Nothing processed yet — dimmed skeleton rows instead of an empty gap.
    private var recentPlaceholder: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.card2)
                        .frame(width: 14, height: 14)
                    Capsule()
                        .fill(theme.card2)
                        .frame(width: [128, 96, 112][index], height: 8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            Text("Your processed files will appear here")
                .font(.system(size: 11))
                .foregroundStyle(theme.dim)
                .padding(.horizontal, 10)
                .padding(.top, 3)
        }
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle()
                    .fill(selectedModelDownloaded ? theme.positive : theme.dim)
                    .frame(width: 7, height: 7)
                Text("Embedded Model")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
            }
            Text(modelLine)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.dim)
        }
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Collapsed rail

    /// Groups mirror the expanded sidebar: skills, then recent history,
    /// then system — separated by hairlines.
    private var rail: some View {
        VStack(spacing: 6) {
            // Empty traffic-light strip — keeps the toggle at the exact
            // same y as in the expanded layout.
            Color.clear
                .frame(height: Self.brandStripHeight - 5)

            toggleButton
                .padding(.bottom, 8)

            railButton(.library)
            railButton(.summary)
            railButton(.captions)

            if !history.entries.isEmpty {
                railDivider
                ForEach(history.entries.prefix(3)) { entry in
                    railHistoryButton(entry)
                }
            }

            railDivider
            railButton(.models)
            railButton(.appearance)

            Spacer(minLength: 12)

            appIcon
                .frame(width: 22, height: 22)

            Circle()
                .fill(selectedModelDownloaded ? theme.positive : theme.dim)
                .frame(width: 7, height: 7)
                .help(modelLine)
                .padding(.bottom, 6)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 12, trailing: 10))
        .frame(width: 52)
    }

    private var railDivider: some View {
        Rectangle()
            .fill(theme.line)
            .frame(width: 22, height: 1)
            .padding(.vertical, 4)
    }

    private func railHistoryButton(_ entry: HistoryEntry) -> some View {
        let isActive = isOpen(entry)
        return Button {
            openEntry(entry)
        } label: {
            VideoThumbView(path: entry.videoPath, cornerRadius: 4)
                .frame(width: 24, height: 16)
                .opacity(entry.fileExists ? 1 : 0.4)
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
        .disabled(!entry.fileExists)
        .help(entry.title)
    }

    private func railButton(_ screen: AppScreen) -> some View {
        let isActive = appState.screen == screen
        return Button {
            appState.screen = screen
        } label: {
            Image(systemName: icon(for: screen))
                .font(.system(size: 13))
                .frame(width: 30, height: 30)
                .background(
                    isActive ? theme.accent : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .foregroundStyle(isActive ? theme.accentOn : theme.text)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(screen.title)
    }

    private var selectedModelDownloaded: Bool {
        modelManager.isSelectedModelDownloaded
    }

    private var modelLine: String {
        guard let model = modelManager.selectedModel else { return "no model selected" }
        return "\(model.name) · ~\(model.ramMb) MB RAM"
    }
}
