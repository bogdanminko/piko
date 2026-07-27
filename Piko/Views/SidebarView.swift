import SwiftUI

/// Fixed navigation sidebar from the design mockup: Workspace / Recent /
/// System sections plus the embedded-model card at the bottom. Collapses
/// into an icon-only rail.
struct SidebarView: View {
    @Bindable var appState: AppState
    var modelManager: ModelManagerVM
    var history: HistoryStore
    var processor: VideoProcessorVM
    var meeting: MeetingVM
    @Environment(\.pikoTheme) private var theme

    /// Recent is the Library's short head: both verticals, newest first, so a
    /// call recorded five minutes ago is one click away from anywhere.
    private var recentItems: [LibraryItem] {
        LibraryItem.all(meetings: meeting.recordings, captions: history.entries)
    }

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
            if recentItems.isEmpty {
                recentPlaceholder
            } else {
                SidebarRecent(layout: .list, items: recentItems, appState: appState,
                              history: history, processor: processor, meeting: meeting)
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
        .cardSurface(theme, radius: 8)
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

            if !recentItems.isEmpty {
                railDivider
                SidebarRecent(layout: .rail, items: recentItems, appState: appState,
                              history: history, processor: processor, meeting: meeting)
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
