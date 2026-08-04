import SwiftUI

enum AppScreen: String, CaseIterable, Identifiable {
    /// Where the app opens and where work happens. One recording, whatever
    /// can be got out of it — not one tab per kind of result.
    case artifact
    case library
    case models
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .artifact: "Workspace"
        case .library: "Library"
        case .models: "Models"
        case .appearance: "Appearance"
        }
    }
}

/// Which artifact the workspace is showing.
///
/// The two verticals used to be two tabs, which made the app ask what kind of
/// work this was *before* it had looked at the file — and made one product
/// read as two. They are results now, not destinations: the pipeline is chosen
/// from the file itself and can be switched afterwards in one click.
enum ArtifactFocus: Equatable {
    /// Nothing open: the workspace shows the way in.
    case none
    case meeting
    case video
}

/// Shell-level state: which screen is open and how the window looks.
/// Theme and translucency persist across launches.
@MainActor
@Observable
final class AppState {
    private static let themeKey = "piko.theme"
    private static let translucentKey = "piko.translucent"
    private static let sidebarKey = "piko.sidebarCollapsed"
    private static let settingsKey = "piko.captionSettingsCollapsed"

    var screen: AppScreen = .artifact

    /// What the workspace is currently working on.
    var focus: ArtifactFocus = .none

    /// The recorder's controls are wanted in the workspace. Shell-level rather
    /// than local to the conversation because "Record a Call" is offered from
    /// the sidebar too, and a recording started from there has to raise the
    /// same bar — `recorder.isActive` alone is false for the seconds a
    /// permission prompt is up, which is exactly when the controls matter.
    var wantsRecorder = false

    /// Load an artifact into the workspace. Everything that opens something —
    /// Library, Recent, a `piko://` link, a drop, a recording — goes through
    /// here, so there is exactly one way to arrive at the work.
    ///
    /// It does **not** select a screen any more. The workspace is the chat,
    /// always; this says which pipeline the thing that just arrived belongs to,
    /// and the conversation opens it in the panel beside itself. Sending a file
    /// to a module screen instead was the whole bug: dropping a video landed on
    /// a transcriber, not in the session that was meant to hold it.
    func show(_ focus: ArtifactFocus) {
        self.focus = focus
        screen = .artifact
    }

    /// Themes loaded from the Themes folder (`ThemeLibrary`); reloaded via
    /// `refreshCustomThemes()` whenever the generator saves or deletes one.
    var customThemes: [ThemeTokens]

    var allThemes: [ThemeTokens] { ThemeTokens.builtins + customThemes }

    var theme: ThemeTokens {
        didSet { UserDefaults.standard.set(theme.id, forKey: Self.themeKey) }
    }

    var translucent: Bool {
        didSet { UserDefaults.standard.set(translucent, forKey: Self.translucentKey) }
    }

    /// Sidebar collapsed to an icon-only rail.
    var sidebarCollapsed: Bool {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: Self.sidebarKey) }
    }

    /// Caption settings panel hidden on the Captions screen.
    var captionSettingsCollapsed: Bool {
        didSet { UserDefaults.standard.set(captionSettingsCollapsed, forKey: Self.settingsKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        let loadedCustomThemes = ThemeLibrary.loadCustomThemes()
        customThemes = loadedCustomThemes
        let savedID = defaults.string(forKey: Self.themeKey)
        theme = (ThemeTokens.builtins + loadedCustomThemes).first { $0.id == savedID } ?? Self.systemDefaultTheme
        translucent = defaults.object(forKey: Self.translucentKey) as? Bool ?? true
        sidebarCollapsed = defaults.bool(forKey: Self.sidebarKey)
        captionSettingsCollapsed = defaults.bool(forKey: Self.settingsKey)
    }

    /// Re-scans the Themes folder — call after the custom-theme generator
    /// saves or deletes a file so the picker grid updates immediately.
    func refreshCustomThemes() {
        customThemes = ThemeLibrary.loadCustomThemes()
        if theme.isCustom, !customThemes.contains(where: { $0.id == theme.id }) {
            theme = Self.systemDefaultTheme
        }
    }

    /// Latte on a light system, Mocha on a dark one — used both as the
    /// first-launch default and as the fallback if a saved/custom theme
    /// can no longer be resolved. "AppleInterfaceStyle" is absent in Light
    /// mode and "Dark" in Dark mode; this is the standard read-only check
    /// for the current system appearance.
    private static var systemDefaultTheme: ThemeTokens {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .mocha : .latte
    }
}
