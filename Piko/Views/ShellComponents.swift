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
/// `compact` is the inline variant that sits inside a card header.
struct AccentButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.pikoTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .padding(.horizontal, compact ? 10 : 13)
            .padding(.vertical, compact ? 4 : 6)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(theme.accentOn)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Quiet bordered button for secondary row actions ("+ Add item", "Restore").
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.pikoTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(theme.dim)
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Chips that wrap onto the next line instead of being clipped.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        var total = CGSize.zero

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > width, origin.x > 0 {
                origin.x = 0
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            total.width = max(total.width, origin.x - spacing)
            total.height = origin.y + lineHeight
        }
        return total
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var origin = bounds.origin
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.maxX, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Square icon button for actions that live inside a row — edit, save, cancel.
/// Quiet until the pointer is on it: a list of items should not read as a list
/// of buttons.
struct RowIconButton: View {
    let icon: String
    let help: String
    /// Nil keeps it neutral; an accent tint marks the affirmative one.
    var tint: Color?
    let action: () -> Void

    @Environment(\.pikoTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .foregroundStyle(tint ?? theme.dim)
                .background(isHovered ? theme.card2 : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// The row's overflow menu, styled like `RowIconButton`.
///
/// Destructive actions live behind it rather than on the row: a bin you can
/// hit while aiming for the pencil is a bin that will be hit, and an undo does
/// not make that acceptable.
struct RowMenuButton<Content: View>: View {
    var icon = "ellipsis"
    var help = "More"
    @ViewBuilder var content: Content

    @Environment(\.pikoTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .foregroundStyle(theme.dim)
                .background(isHovered ? theme.card2 : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help(help)
    }
}
