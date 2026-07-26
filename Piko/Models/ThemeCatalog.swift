import SwiftUI

/// The 9 themes Piko ships with — 4 light, 5 dark. The first 3 keep their
/// original hex values and `id`s unchanged so a theme picked before this
/// catalog grew still resolves the same way. Latte·Teal/Macchiato/
/// Mocha·Matcha are Catppuccin flavor/accent combos that weren't shipped
/// yet; Nocturne/Organic/Modernist port the color identity of the three
/// alternate design systems explored on claude.ai/design into Piko's
/// existing shape language (radius, density and type are unchanged — only
/// tokens differ).
extension ThemeTokens {
    static let latte = ThemeTokens(
        id: "latte",
        displayName: "Latte",
        subtitle: "Built-in · Catppuccin light",
        isDark: false,
        isCustom: false,
        accentHex: HexColor("1E66F5"),
        accentOnHex: HexColor("EFF1F5"),
        positiveHex: HexColor("40A02B"),
        chromeHex: HexColor("E6E9EF"),
        paneHex: HexColor("EFF1F5"),
        cardHex: HexColor("DCE0E8", opacity: 0.72),
        card2Hex: HexColor("BCC0CC", opacity: 0.55),
        textHex: HexColor("4C4F69"),
        dimHex: HexColor("5C5F77"),
        lineHex: HexColor("4C4F69", opacity: 0.18),
        previewGradientHex: [HexColor("EFF1F5"), HexColor("C3C9DE")]
    )

    static let latteTeal: ThemeTokens = {
        let accent = Color(hex: "179299")
        let pane = Color(hex: "EFF1F5")
        return ThemeTokens(
            id: "latteTeal",
            displayName: "Latte · Teal",
            subtitle: "Built-in · Catppuccin latte, teal accent",
            isDark: false,
            isCustom: false,
            accentHex: HexColor(accent),
            accentOnHex: HexColor("EFF1F5"),
            positiveHex: HexColor("40A02B"),
            chromeHex: HexColor("E6E9EF"),
            paneHex: HexColor(pane),
            cardHex: HexColor("DCE0E8", opacity: 0.72),
            card2Hex: HexColor("BCC0CC", opacity: 0.55),
            textHex: HexColor("4C4F69"),
            dimHex: HexColor("5C5F77"),
            lineHex: HexColor("4C4F69", opacity: 0.18),
            previewGradientHex: [HexColor(pane), HexColor(ThemeGenerator.mix(pane, accent, 0.35))]
        )
    }()

    static let mocha = ThemeTokens(
        id: "mocha",
        displayName: "Mocha",
        subtitle: "Built-in · Catppuccin dark",
        isDark: true,
        isCustom: false,
        accentHex: HexColor("CBA6F7"),
        accentOnHex: HexColor("1E1E2E"),
        positiveHex: HexColor("A6E3A1"),
        chromeHex: HexColor("181825"),
        paneHex: HexColor("1E1E2E"),
        cardHex: HexColor("CDD6F4", opacity: 0.06),
        card2Hex: HexColor("CDD6F4", opacity: 0.11),
        textHex: HexColor("CDD6F4"),
        dimHex: HexColor("9399B2"),
        lineHex: HexColor("CDD6F4", opacity: 0.11),
        previewGradientHex: [HexColor("11111B"), HexColor("45385E")]
    )

    static let frappePeach = ThemeTokens(
        id: "frappePeach",
        displayName: "Frappé Peach",
        subtitle: "Built-in · Catppuccin frappé",
        isDark: true,
        isCustom: false,
        accentHex: HexColor("EF9F76"),
        accentOnHex: HexColor("303446"),
        positiveHex: HexColor("85C1DC"),
        chromeHex: HexColor("292C3C"),
        paneHex: HexColor("303446"),
        cardHex: HexColor("C6D0F5", opacity: 0.07),
        card2Hex: HexColor("C6D0F5", opacity: 0.12),
        textHex: HexColor("C6D0F5"),
        dimHex: HexColor("949CBB"),
        lineHex: HexColor("C6D0F5", opacity: 0.12),
        previewGradientHex: [HexColor("232634"), HexColor("5B4A44")]
    )

    static let macchiato: ThemeTokens = {
        let accent = Color(hex: "B7BDF8") // Lavender
        let pane = Color(hex: "24273A") // Base
        let text = Color(hex: "CAD3F5")
        let accentOn = ThemeGenerator.pickAccentOn(accent: accent, text: text, pane: pane, isDark: true)
        return ThemeTokens(
            id: "macchiato",
            displayName: "Macchiato",
            subtitle: "Built-in · Catppuccin macchiato",
            isDark: true,
            isCustom: false,
            accentHex: HexColor(accent),
            accentOnHex: HexColor(accentOn),
            positiveHex: HexColor("A6DA95"), // Green
            chromeHex: HexColor("1E2030"), // Mantle
            paneHex: HexColor(pane),
            cardHex: HexColor("CAD3F5", opacity: 0.06),
            card2Hex: HexColor("CAD3F5", opacity: 0.11),
            textHex: HexColor(text),
            dimHex: HexColor("A5ADCB"), // Subtext 0
            lineHex: HexColor("CAD3F5", opacity: 0.11),
            previewGradientHex: [HexColor("1E2030"), HexColor(ThemeGenerator.mix(pane, accent, 0.35))]
        )
    }()

    static let mochaMatcha: ThemeTokens = {
        let accent = Color(hex: "A6E3A1") // Green
        let pane = Color(hex: "1E1E2E")
        let text = Color(hex: "CDD6F4")
        let accentOn = ThemeGenerator.pickAccentOn(accent: accent, text: text, pane: pane, isDark: true)
        return ThemeTokens(
            id: "mochaMatcha",
            displayName: "Mocha · Matcha",
            subtitle: "Built-in · Catppuccin mocha, green accent",
            isDark: true,
            isCustom: false,
            accentHex: HexColor(accent),
            accentOnHex: HexColor(accentOn),
            positiveHex: HexColor("94E2D5"), // Teal
            chromeHex: HexColor("181825"),
            paneHex: HexColor(pane),
            cardHex: HexColor("CDD6F4", opacity: 0.06),
            card2Hex: HexColor("CDD6F4", opacity: 0.11),
            textHex: HexColor(text),
            dimHex: HexColor("9399B2"),
            lineHex: HexColor("CDD6F4", opacity: 0.11),
            previewGradientHex: [HexColor("11111B"), HexColor(ThemeGenerator.mix(pane, accent, 0.35))]
        )
    }()

    static let nocturne: ThemeTokens = {
        let accent = Color(hex: "9184D9")
        let pane = Color(hex: "161826")
        let text = Color(hex: "E9E9ED")
        let chrome = Color(hex: "12141F")
        let accentOn = ThemeGenerator.pickAccentOn(accent: accent, text: text, pane: pane, isDark: true)
        return ThemeTokens(
            id: "nocturne",
            displayName: "Nocturne",
            subtitle: "Built-in · dark, compact, blurple",
            isDark: true,
            isCustom: false,
            accentHex: HexColor(accent),
            accentOnHex: HexColor(accentOn),
            positiveHex: HexColor("A6E3A1"),
            chromeHex: HexColor(chrome),
            paneHex: HexColor(pane),
            cardHex: HexColor("E9E9ED", opacity: 0.06),
            card2Hex: HexColor("E9E9ED", opacity: 0.11),
            textHex: HexColor(text),
            dimHex: HexColor("8B8FA3"),
            lineHex: HexColor("E9E9ED", opacity: 0.11),
            previewGradientHex: [HexColor(chrome), HexColor(ThemeGenerator.mix(pane, accent, 0.35))]
        )
    }()

    static let organic: ThemeTokens = {
        let accent = Color(hex: "C67139") // Terracotta
        let pane = Color(hex: "F5EAD8")
        let text = Color(hex: "201E1D")
        let chrome = Color(hex: "EDE0CB")
        let accentOn = ThemeGenerator.pickAccentOn(accent: accent, text: text, pane: pane, isDark: false)
        let card = ThemeGenerator.mix(text, pane, 0.55).opacity(0.6)
        let card2 = ThemeGenerator.mix(text, pane, 0.40).opacity(0.55)
        return ThemeTokens(
            id: "organic",
            displayName: "Organic",
            subtitle: "Built-in · warm, terracotta & sage",
            isDark: false,
            isCustom: false,
            accentHex: HexColor(accent),
            accentOnHex: HexColor(accentOn),
            positiveHex: HexColor("7A8A5E"), // Sage
            chromeHex: HexColor(chrome),
            paneHex: HexColor(pane),
            cardHex: HexColor(card),
            card2Hex: HexColor(card2),
            textHex: HexColor(text),
            dimHex: HexColor("6B6560"),
            lineHex: HexColor(text.opacity(0.18)),
            previewGradientHex: [HexColor(chrome), HexColor(ThemeGenerator.mix(pane, accent, 0.35))]
        )
    }()

    static let modernist: ThemeTokens = {
        let accent = Color(hex: "EC3013")
        let pane = Color(hex: "F3F2F2")
        let text = Color(hex: "201E1D")
        let chrome = Color(hex: "E8E6E5")
        let accentOn = ThemeGenerator.pickAccentOn(accent: accent, text: text, pane: pane, isDark: false)
        let card = ThemeGenerator.mix(text, pane, 0.55).opacity(0.6)
        let card2 = ThemeGenerator.mix(text, pane, 0.40).opacity(0.55)
        return ThemeTokens(
            id: "modernist",
            displayName: "Modernist",
            subtitle: "Built-in · flat, architectural, red on white",
            isDark: false,
            isCustom: false,
            accentHex: HexColor(accent),
            accentOnHex: HexColor(accentOn),
            positiveHex: HexColor("40A02B"),
            chromeHex: HexColor(chrome),
            paneHex: HexColor(pane),
            cardHex: HexColor(card),
            card2Hex: HexColor(card2),
            textHex: HexColor(text),
            dimHex: HexColor("6B6866"),
            lineHex: HexColor(text.opacity(0.18)),
            previewGradientHex: [HexColor(chrome), HexColor(ThemeGenerator.mix(pane, accent, 0.35))]
        )
    }()

    static let builtins: [ThemeTokens] = [
        .latte, .latteTeal, .mocha, .frappePeach, .macchiato, .mochaMatcha, .nocturne, .organic, .modernist
    ]
}
