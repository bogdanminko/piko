import AppKit
import SwiftUI

/// Behind-window blur used when Translucency is on.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// Small uppercase section label ("WORKSPACE", "DECISIONS", …).
struct SectionLabel: View {
    let text: String
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(theme.dim)
    }
}

extension View {
    /// Card fill plus a hairline edge. Light themes need the outline: their
    /// card sits only a few percent above the pane in luminance, so it is the
    /// edge — not the fill — that makes the surface read as a card. On dark
    /// themes the same hairline just sharpens an already-visible step.
    func cardSurface(_ theme: ThemeTokens, radius: CGFloat = 10) -> some View {
        background(theme.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(theme.line, lineWidth: 1))
    }
}

/// Rounded content card matching the mockup's `--card` fill.
struct ThemedCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        content
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(theme)
    }
}

/// Badge for screens whose backend does not exist yet.
struct ComingSoonBadge: View {
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(theme.accent).frame(width: 6, height: 6)
            Text("Coming soon")
                .font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(theme.card2, in: Capsule())
        .foregroundStyle(theme.text)
    }
}

/// Header shared by all screens: big title, optional subtitle, trailing
/// accessory, hairline below.
struct ScreenHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(theme.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.dim)
                    }
                }
                Spacer()
                accessory
            }
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }
}

/// Timecode chip in the mockup's mono accent style.
struct Timecode: View {
    let text: String
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(theme.accent)
    }
}

/// Small square icon button used for collapsing panels.
struct PanelToggleButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 26, height: 26)
                .background(theme.card2, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(theme.dim)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Accent-filled primary button ("Export Markdown", "Render styled video").
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.pikoTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(theme.accentOn)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
