import AppKit
import SwiftUI

/// Color math shared by the custom-theme generator and by the "ported"
/// built-in themes (Nocturne, Organic, Modernist), which specify a
/// background/text/accent triad and lean on `mix`/`pickAccentOn` for the rest.
enum ThemeGenerator {
    /// WCAG relative luminance (0 = black, 1 = white) on linearized sRGB.
    static func relativeLuminance(_ color: Color) -> Double {
        let resolved = color.resolve(in: EnvironmentValues())
        func linearize(_ channel: Float) -> Double {
            let value = Double(channel)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(resolved.red)
            + 0.7152 * linearize(resolved.green)
            + 0.0722 * linearize(resolved.blue)
    }

    /// Linear RGBA interpolation between two colors.
    static func mix(_ from: Color, _ to: Color, _ fraction: Double) -> Color {
        let ra = from.resolve(in: EnvironmentValues())
        let rb = to.resolve(in: EnvironmentValues())
        let amount = Float(fraction)
        func lerp(_ start: Float, _ end: Float) -> Float { start + (end - start) * amount }
        return Color(
            .sRGB,
            red: Double(lerp(ra.red, rb.red)),
            green: Double(lerp(ra.green, rb.green)),
            blue: Double(lerp(ra.blue, rb.blue)),
            opacity: Double(lerp(ra.opacity, rb.opacity))
        )
    }

    /// Picks whichever of a theme's own `text`/`pane` tokens contrasts better
    /// against `accent` — `text`/`pane` swap which one reads as "light" and
    /// which reads as "dark" depending on `isDark`, so the candidates are
    /// sorted by their actual brightness rather than by name.
    static func pickAccentOn(accent: Color, text: Color, pane: Color, isDark: Bool) -> Color {
        let lightCandidate = isDark ? text : pane
        let darkCandidate = isDark ? pane : text
        return relativeLuminance(accent) > 0.5 ? darkCandidate : lightCandidate
    }

    private static func hue(of color: Color) -> Double {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        var hueValue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        nsColor.getHue(&hueValue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Double(hueValue)
    }

    private static func neutral(hue: Double, saturation: Double, brightness: Double) -> Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// Derives a full token set from a single accent color + light/dark
    /// choice — the whole custom-theme generator algorithm.
    static func generate(name: String, accentColor: Color, isDark: Bool) -> ThemeTokens {
        let hue = hue(of: accentColor)
        let neutralSat = 0.08

        let chrome: Color
        let pane: Color
        let text: Color
        let dim: Color
        let card: Color
        let card2: Color
        let line: Color
        let positive: Color

        if isDark {
            chrome = neutral(hue: hue, saturation: neutralSat, brightness: 0.10)
            pane = neutral(hue: hue, saturation: neutralSat, brightness: 0.13)
            text = neutral(hue: hue, saturation: 0.04, brightness: 0.92)
            dim = neutral(hue: hue, saturation: 0.05, brightness: 0.62)
            card = text.opacity(0.06)
            card2 = text.opacity(0.11)
            line = text.opacity(0.11)
            positive = Color(hex: "A6E3A1") // Catppuccin Mocha green
        } else {
            // Light themes invert the dark ladder: cards sit *above* the pane,
            // so they get brighter, not darker. Deriving them from `text`
            // (as this branch used to) turns every card into a gray wash.
            chrome = neutral(hue: hue, saturation: neutralSat, brightness: 0.92)
            pane = neutral(hue: hue, saturation: neutralSat * 0.55, brightness: 0.97)
            text = neutral(hue: hue, saturation: 0.18, brightness: 0.18)
            dim = neutral(hue: hue, saturation: 0.12, brightness: 0.40)
            card = neutral(hue: hue, saturation: neutralSat * 0.3, brightness: 0.995)
            card2 = neutral(hue: hue, saturation: neutralSat * 1.4, brightness: 0.89)
            line = text.opacity(0.14)
            positive = Color(hex: "40A02B") // Catppuccin Latte green
        }

        let accentOn = pickAccentOn(accent: accentColor, text: text, pane: pane, isDark: isDark)
        let previewGradient = [chrome, mix(pane, accentColor, 0.35)]

        return ThemeTokens(
            id: UUID().uuidString,
            displayName: name,
            subtitle: "Custom · \(isDark ? "Dark" : "Light")",
            isDark: isDark,
            isCustom: true,
            accentHex: HexColor(accentColor),
            accentOnHex: HexColor(accentOn),
            positiveHex: HexColor(positive),
            chromeHex: HexColor(chrome),
            paneHex: HexColor(pane),
            cardHex: HexColor(card),
            card2Hex: HexColor(card2),
            textHex: HexColor(text),
            dimHex: HexColor(dim),
            lineHex: HexColor(line),
            previewGradientHex: previewGradient.map(HexColor.init)
        )
    }
}
