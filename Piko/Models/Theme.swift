import SwiftUI

/// Runtime color tokens for one shell theme. Built-in themes live in
/// `ThemeTokens.builtins` (ThemeCatalog.swift); user-generated ones are
/// produced by `ThemeGenerator.generate` and loaded from `.piko-theme.json`
/// files via `ThemeLibrary` — both are this exact same type, so the rest of
/// the app never needs to know which kind it's holding.
struct ThemeTokens: Identifiable, Equatable {
    var id: String
    var displayName: String
    var subtitle: String
    var isDark: Bool
    /// True when this theme was loaded from a Themes-folder file rather than
    /// being one of the built-ins — controls whether it gets a Delete menu.
    var isCustom: Bool

    var accentHex: HexColor
    var accentOnHex: HexColor
    var positiveHex: HexColor
    var chromeHex: HexColor
    var paneHex: HexColor
    var cardHex: HexColor
    var card2Hex: HexColor
    var textHex: HexColor
    var dimHex: HexColor
    var lineHex: HexColor
    /// Always 2 entries; used by the theme preview cards' gradient.
    var previewGradientHex: [HexColor]

    /// System controls must follow the theme, not the OS setting.
    var colorScheme: ColorScheme { isDark ? .dark : .light }

    var accent: Color { accentHex.color }
    var accentOn: Color { accentOnHex.color }
    var positive: Color { positiveHex.color }
    var chrome: Color { chromeHex.color }
    var pane: Color { paneHex.color }
    var card: Color { cardHex.color }
    var card2: Color { card2Hex.color }
    var text: Color { textHex.color }
    var dim: Color { dimHex.color }
    var line: Color { lineHex.color }
    var previewGradient: [Color] { previewGradientHex.map(\.color) }
}

// MARK: - Hex color

/// An RGBA color stored as an 8-digit "RRGGBBAA" hex string — the single
/// vocabulary `.piko-theme.json` uses for every token, including the ones
/// that carry opacity (card/card2/line).
struct HexColor: Equatable {
    /// Always 8 uppercase hex digits, no "#".
    let hex: String

    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        self.hex = digits.count == 8 ? digits : digits + "FF"
    }

    /// Convenience for catalog code: a 6-digit base color plus a separate
    /// opacity, e.g. `HexColor("CDD6F4", opacity: 0.06)`.
    init(_ hex6: String, opacity: Double = 1) {
        self.init(Color(hex: hex6).opacity(opacity))
    }

    init(_ color: Color) {
        self.hex = color.hex8
    }

    var color: Color { Color(hex: hex) }
}

extension HexColor: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(hex: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode("#" + hex)
    }
}

extension Color {
    /// Init from "#RRGGBB" or "#RRGGBBAA".
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0xFFD700FF
        if digits.count == 8 {
            self.init(
                .sRGB,
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                opacity: Double(value & 0xFF) / 255
            )
        } else {
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        }
    }

    /// "RRGGBBAA" hex string, via `Color.Resolved` (macOS 14+).
    var hex8: String {
        let resolved = resolve(in: EnvironmentValues())
        func byte(_ component: Float) -> Int {
            Int((component.isFinite ? component : 0).clamped(to: 0...1) * 255)
        }
        return String(
            format: "%02X%02X%02X%02X",
            byte(resolved.red), byte(resolved.green), byte(resolved.blue), byte(resolved.opacity)
        )
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Environment

private struct PikoThemeKey: EnvironmentKey {
    static let defaultValue = ThemeTokens.mocha
}

extension EnvironmentValues {
    var pikoTheme: ThemeTokens {
        get { self[PikoThemeKey.self] }
        set { self[PikoThemeKey.self] = newValue }
    }
}
