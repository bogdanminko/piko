import SwiftUI

enum AppScreen: String, CaseIterable, Identifiable {
    case library
    case summary
    case captions
    case models
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .summary: "Meeting Summary"
        case .captions: "Captions"
        case .models: "Models"
        case .appearance: "Appearance"
        }
    }
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

    var screen: AppScreen = .library

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
