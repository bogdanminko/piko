import SwiftUI

/// On-disk shape of a `.piko-theme.json` file — the format both the custom
/// theme generator's Save button and a hand-authored community theme use.
struct ThemeFile: Codable {
    struct Colors: Codable {
        var accent: HexColor
        var accentOn: HexColor
        var positive: HexColor
        var chrome: HexColor
        var pane: HexColor
        var card: HexColor
        var card2: HexColor
        var text: HexColor
        var dim: HexColor
        var line: HexColor
        var previewGradient: [HexColor]
    }

    var schema: Int
    var id: String
    var name: String
    var isDark: Bool
    var colors: Colors
}

extension ThemeFile {
    init(_ theme: ThemeTokens) {
        schema = 1
        id = theme.id
        name = theme.displayName
        isDark = theme.isDark
        colors = Colors(
            accent: theme.accentHex,
            accentOn: theme.accentOnHex,
            positive: theme.positiveHex,
            chrome: theme.chromeHex,
            pane: theme.paneHex,
            card: theme.cardHex,
            card2: theme.card2Hex,
            text: theme.textHex,
            dim: theme.dimHex,
            line: theme.lineHex,
            previewGradient: theme.previewGradientHex
        )
    }

    /// `nil` when the file doesn't carry every token Piko needs (a bad
    /// `previewGradient` arity slips past `Decodable` since the field type
    /// itself is still valid JSON) — malformed JSON fails earlier, at decode.
    var tokens: ThemeTokens? {
        guard colors.previewGradient.count == 2 else { return nil }
        return ThemeTokens(
            id: id,
            displayName: name,
            subtitle: "Custom",
            isDark: isDark,
            isCustom: true,
            accentHex: colors.accent,
            accentOnHex: colors.accentOn,
            positiveHex: colors.positive,
            chromeHex: colors.chrome,
            paneHex: colors.pane,
            cardHex: colors.card,
            card2Hex: colors.card2,
            textHex: colors.text,
            dimHex: colors.dim,
            lineHex: colors.line,
            previewGradientHex: colors.previewGradient
        )
    }
}
