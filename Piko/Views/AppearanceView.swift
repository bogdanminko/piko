import AppKit
import SwiftUI

/// Theme picker and window material settings. Built-in themes and custom
/// themes generated in-app (or dropped into the Themes folder as
/// `.piko-theme.json`) share the same picker grid.
struct AppearanceView: View {
    @Bindable var appState: AppState
    @Environment(\.pikoTheme) private var theme
    @State private var showingGenerator = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(
                title: "Appearance",
                subtitle: "Pick a built-in style, or generate your own from a single accent color."
            ) {
                EmptyView()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(appState.allThemes) { candidate in
                    themeCard(candidate)
                }
                createThemeCard
            }
            .sheet(isPresented: $showingGenerator) {
                CustomThemeGeneratorView(appState: appState)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    translucencyCard
                    languageCard
                }
                .frame(maxWidth: .infinity)
                themesFolderCard
                    .frame(width: 320)
            }

            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
    }

    private func themeCard(_ candidate: ThemeTokens) -> some View {
        let isActive = appState.theme.id == candidate.id
        return Button {
            appState.theme = candidate
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 6) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(candidate.accent)
                        .frame(width: 20, height: 20)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(candidate.positive)
                        .frame(width: 20, height: 20)
                    Capsule()
                        .fill(.white.opacity(candidate.isDark ? 0.14 : 0.75))
                        .frame(height: 8)
                }
                .padding(9)
                .frame(height: 62, alignment: .bottomLeading)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .background(
                    LinearGradient(colors: candidate.previewGradient,
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(candidate.displayName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(theme.text)
                        statusChip(active: isActive)
                    }
                    Text(candidate.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isActive ? theme.accent : theme.line, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if candidate.isCustom {
                Button("Reveal in Finder") { revealThemesFolder() }
                Button("Delete", role: .destructive) { deleteCustomTheme(candidate) }
            }
        }
    }

    private var createThemeCard: some View {
        Button {
            showingGenerator = true
        } label: {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                Image(systemName: "plus.circle")
                    .font(.system(size: 20))
                Text("Create custom theme")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.dim)
            .frame(maxWidth: .infinity, minHeight: 116)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func revealThemesFolder() {
        try? FileManager.default.createDirectory(
            at: ThemeLibrary.themesFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ThemeLibrary.themesFolder)
    }

    private func deleteCustomTheme(_ candidate: ThemeTokens) {
        try? ThemeLibrary.delete(candidate)
        appState.refreshCustomThemes()
    }

    private var translucencyCard: some View {
        ThemedCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translucency")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text)
                    Text("Window and sidebar material")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                }
                Spacer()
                Toggle("", isOn: $appState.translucent)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(theme.accent)
            }
        }
    }

    private func statusChip(active: Bool) -> some View {
        Text(active ? "Active" : "Apply")
            .font(.system(size: 10.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(active ? theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                if !active {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(theme.line)
                }
            }
            .foregroundStyle(active ? theme.accentOn : theme.dim)
    }

    /// UI localization (RU/EN/DE/FR in the mockup) is designed but not
    /// implemented — the app is English-only for now.
    private var languageCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionLabel(text: "Interface language")
                    Spacer()
                    ComingSoonBadge()
                }
                HStack(spacing: 6) {
                    ForEach(["EN", "FR", "DE", "RU"], id: \.self) { lang in
                        Text(lang)
                            .font(.system(size: 12))
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(lang == "EN" ? theme.card2 : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(lang == "EN" ? theme.accent : theme.line)
                            }
                            .foregroundStyle(lang == "EN" ? theme.text : theme.dim)
                    }
                }
            }
        }
        .opacity(0.75)
    }

    private var themesFolderCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Themes folder")
                Text(ThemeLibrary.themesFolder.path)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.card2, in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(theme.dim)
                Text("Piko scans this folder for `.piko-theme.json` files and lists them "
                     + "above, next to the built-in styles. A file that fails to parse is "
                     + "skipped — it's never applied and never crashes Piko.")
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(theme.dim)
                Button("Reveal in Finder") { revealThemesFolder() }
                    .controlSize(.small)
            }
        }
    }
}
