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

    /// A color's HSB components in device RGB.
    struct HSB {
        var hue: Double
        var saturation: Double
        var brightness: Double
    }

    private static func hsb(of color: Color) -> HSB {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        var hueValue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        nsColor.getHue(&hueValue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return HSB(hue: Double(hueValue), saturation: Double(saturation), brightness: Double(brightness))
    }

    /// Shortest distance between two hues on the wheel (0...0.5).
    private static func hueDistance(_ one: Double, _ other: Double) -> Double {
        let raw = abs(one - other).truncatingRemainder(dividingBy: 1)
        return min(raw, 1 - raw)
    }

    /// The affirmative color is a *state*, not decoration: a dozen places draw
    /// `isDone ? theme.positive : theme.accent`, so it has to read as success
    /// *and* stay distinguishable from the accent. A hardcoded Catppuccin
    /// green did the first and ignored the second — a purple or amber theme
    /// got a leaf green that belonged to no other token on screen, which is
    /// not how the built-ins do it (Frappé Peach answers in blue, Mocha ·
    /// Matcha in teal precisely because its accent is the green one).
    ///
    /// So it is derived like every other token: the hue stays in the
    /// green→teal range every UI on this planet reads as "done", and moves to
    /// the teal end when the accent itself is green; saturation and brightness
    /// come from the accent, clamped to what is legible on this theme's
    /// background; and a tenth of the accent is mixed back in so it reads as
    /// the same family rather than a second opinion.
    static func derivePositive(accent: Color, isDark: Bool) -> Color {
        let greenHue = 0.34, tealHue = 0.47
        let source = hsb(of: accent)
        let hue = hueDistance(source.hue, greenHue) < 0.09 ? tealHue : greenHue

        let saturation: Double
        let brightness: Double
        if isDark {
            // Pastel over a near-black pane, the range A6E3A1/94E2D5 sit in.
            saturation = min(max(source.saturation, 0.25), 0.60)
            brightness = min(max(source.brightness, 0.72), 0.95)
        } else {
            // Deep enough to survive on near-white, the range 40A02B sits in.
            saturation = min(max(source.saturation, 0.55), 0.95)
            brightness = min(max(source.brightness, 0.42), 0.68)
        }
        return mix(Color(hue: hue, saturation: saturation, brightness: brightness), accent, 0.10)
    }

    private static func neutral(hue: Double, saturation: Double, brightness: Double) -> Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// Derives a full token set from an accent color + light/dark choice —
    /// the whole custom-theme generator algorithm. `positiveColor` is the one
    /// derivation a person can overrule (see `derivePositive`); passing nil
    /// keeps it tied to the accent.
    static func generate(
        name: String,
        accentColor: Color,
        isDark: Bool,
        positiveColor: Color? = nil
    ) -> ThemeTokens {
        let hue = hsb(of: accentColor).hue
        let neutralSat = 0.08

        let chrome: Color
        let pane: Color
        let text: Color
        let dim: Color
        let card: Color
        let card2: Color
        let line: Color
        let positive = positiveColor ?? derivePositive(accent: accentColor, isDark: isDark)

        if isDark {
            chrome = neutral(hue: hue, saturation: neutralSat, brightness: 0.10)
            pane = neutral(hue: hue, saturation: neutralSat, brightness: 0.13)
            text = neutral(hue: hue, saturation: 0.04, brightness: 0.92)
            dim = neutral(hue: hue, saturation: 0.05, brightness: 0.62)
            card = text.opacity(0.06)
            card2 = text.opacity(0.11)
            line = text.opacity(0.11)
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
