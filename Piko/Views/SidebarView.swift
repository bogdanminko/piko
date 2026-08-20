import SwiftUI

/// Fixed navigation sidebar: New session, the conversations this launch has,
/// then the app-level screens. Collapses into an icon-only rail.
struct SidebarView: View {
    @Bindable var appState: AppState
    @Bindable var store: SessionStore
    var modelManager: ModelManagerVM
    /// The summarizer, so the card can say whether it is holding memory and
    /// offer to give it back.
    @Bindable var summarizer: SummarizerVM
    /// Start a new conversation. Lives in the sidebar so it is reachable from
    /// every screen — being three clicks deep in an artifact and changing your
    /// mind used to be a dead end.
    var onNewSession: () -> Void
    @Environment(\.pikoTheme) private var theme

    /// One button, one meaning. It used to be a menu — Record a Call / Open a
    /// File… / Empty Workspace — which asked what you were about to do before
    /// you had anything in hand. That is the entrance the workspace was built
    /// to remove, and having it here undid the removal. The new session is
    /// empty; what it becomes is decided by what you hand it, in it.
    private var newSessionButton: some View {
        Button(action: onNewSession) {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text("New session")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.card2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(theme.line)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New session")
    }

    private var newSessionRailButton: some View {
        Button(action: onNewSession) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12))
                .foregroundStyle(theme.text)
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.card2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(theme.line)
                        }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 26, height: 26)
        .help("New session")
    }

    private static let icons: [AppScreen: String] = [
        .artifact: "waveform.circle",
        .library: "square.grid.2x2",
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

            newSessionButton
                .padding(.bottom, 12)

            // The conversations, scrollable: this is the list that grows, and
            // the model card at the bottom is not something to have to scroll
            // past to reach.
            SectionLabel(text: "Chats")
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 5, trailing: 8))
            ScrollView {
                SidebarSessions(layout: .list, store: store, appState: appState)
            }
            .scrollIndicators(.never)

            SectionLabel(text: "System")
                .padding(EdgeInsets(top: 14, leading: 10, bottom: 5, trailing: 10))
            navButton(.library)
            navButton(.models)
            navButton(.appearance)

            modelCard
                .padding(.top, 12)
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

    /// What is on this machine, and what is currently in its memory.
    ///
    /// Two different facts that used to be one line. "Downloaded" is about the
    /// disk and never changes; "resident" is about RAM right now and is the one
    /// worth an eject button — a summarizer nobody is using is gigabytes a
    /// laptop would rather have back.
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle()
                    .fill(selectedModelDownloaded ? theme.positive : theme.dim)
                    .frame(width: 7, height: 7)
                Text("Embedded Model")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
                Spacer(minLength: 4)
                if summarizer.isModelResident {
                    Button { summarizer.eject() } label: {
                        Image(systemName: "eject")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.dim)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Free the summarizer's memory now")
                    .accessibilityLabel("Eject the summarizer")
                }
            }
            Text(modelLine)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.dim)
            if let residency {
                HStack(spacing: 5) {
                    Circle().fill(theme.accent).frame(width: 5, height: 5)
                    Text(residency)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.accent)
                }
            }
        }
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(theme, radius: 8)
        // Cheap and only while the sidebar is on screen: one JSON line to a
        // process that is already running.
        .task {
            while !Task.isCancelled {
                summarizer.refreshStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// "summarizer · 4.4 GB" — reported by MLX, not estimated.
    ///
    /// Names the tier when the resident one is *not* the chosen one, which is
    /// the state right after switching models: the old weights are still held
    /// and the next request is what swaps them.
    private var residency: String? {
        guard summarizer.isModelResident else { return nil }
        let what = summarizer.residentTier.map { "\($0) · still loaded" } ?? "summarizer"
        guard let bytes = summarizer.residentBytes, bytes > 0 else { return what }
        return String(format: "%@ · %.1f GB", what, Double(bytes) / 1_073_741_824)
    }

    // MARK: - Collapsed rail

    /// Groups mirror the expanded sidebar: new session, the conversations,
    /// then the app-level screens — separated by hairlines.
    private var rail: some View {
        VStack(spacing: 6) {
            // Empty traffic-light strip — keeps the toggle at the exact
            // same y as in the expanded layout.
            Color.clear
                .frame(height: Self.brandStripHeight - 5)

            toggleButton
                .padding(.bottom, 8)

            newSessionRailButton
                .padding(.bottom, 2)

            railDivider
            SidebarSessions(layout: .rail, store: store, appState: appState)

            railDivider
            railButton(.library)
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
