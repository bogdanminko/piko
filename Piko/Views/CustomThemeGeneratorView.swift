import SwiftUI

/// Sheet for generating a custom theme from an accent color plus a
/// light/dark choice — Piko derives the rest of the token set
/// (`ThemeGenerator.generate`) and shows it live before Save writes it to
/// the Themes folder as a `.piko-theme.json` file.
///
/// The preview card has always shown two colors, and only one of them could
/// be chosen. The second one — the success/done state — is derived from the
/// accent now rather than being a fixed green, and this sheet lets it be
/// overruled: it stays tied to the accent until somebody picks a color, and
/// Reset ties it back. A knob that silently overrides itself the next time
/// you touch the accent would be worse than no knob.
struct CustomThemeGeneratorView: View {
    @Bindable var appState: AppState
    @Environment(\.pikoTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var accentColor = Color(hex: "8AADF4")
    @State private var isDark = true
    @State private var name = ""
    /// nil = follow the accent.
    @State private var positiveOverride: Color?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var positiveColor: Color {
        positiveOverride ?? ThemeGenerator.derivePositive(accent: accentColor, isDark: isDark)
    }

    private var positiveBinding: Binding<Color> {
        Binding(get: { positiveColor }, set: { positiveOverride = $0 })
    }

    private var preview: ThemeTokens {
        ThemeGenerator.generate(
            name: trimmedName.isEmpty ? "Custom" : trimmedName,
            accentColor: accentColor,
            isDark: isDark,
            positiveColor: positiveOverride
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create custom theme")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.text)

            VStack(alignment: .leading, spacing: 12) {
                ColorPicker("Accent color", selection: $accentColor, supportsOpacity: false)
                    .foregroundStyle(theme.dim)
                successRow
                Picker("", selection: $isDark) {
                    Text("Dark").tag(true)
                    Text("Light").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            previewCard

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(trimmedName.isEmpty)
                    .opacity(trimmedName.isEmpty ? 0.5 : 1)
            }
        }
        .padding(22)
        .frame(width: 360)
        .background(theme.pane)
    }

    /// "Success" rather than "second color": it is what a finished run, a
    /// loaded model and a sent action item are drawn in, and naming it after
    /// its job is what stops somebody picking a second accent here.
    private var successRow: some View {
        HStack(spacing: 8) {
            ColorPicker("Success color", selection: positiveBinding, supportsOpacity: false)
                .foregroundStyle(theme.dim)
            if positiveOverride == nil {
                Text("Auto")
                    .font(.system(size: 10.5))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(theme.dim)
            } else {
                Button("Reset") { positiveOverride = nil }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.accent)
            }
        }
    }

    private var previewCard: some View {
        let candidate = preview
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 6) {
                RoundedRectangle(cornerRadius: 6).fill(candidate.accent).frame(width: 20, height: 20)
                RoundedRectangle(cornerRadius: 6).fill(candidate.positive).frame(width: 20, height: 20)
                Capsule().fill(.white.opacity(candidate.isDark ? 0.14 : 0.75)).frame(height: 8)
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
                Text(candidate.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(candidate.text)
                Text(candidate.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(candidate.dim)
            }
            // The two colors in their actual roles — a swatch pair says
            // nothing about whether "done" still reads as done next to
            // "active", which is the only thing worth checking here.
            HStack(spacing: 6) {
                roleChip("Active", color: candidate.accent, on: candidate.accentOn, filled: true)
                roleChip("Done", color: candidate.positive, on: candidate.accentOn, filled: false)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(candidate.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(candidate.accent, lineWidth: 1)
        }
        .padding(10)
        .background(candidate.pane, in: RoundedRectangle(cornerRadius: 12))
    }

    private func roleChip(_ label: String, color: Color, on: Color, filled: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: filled ? "circle.fill" : "checkmark")
                .font(.system(size: 8, weight: .bold))
            Text(label).font(.system(size: 10.5, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(filled ? color : color.opacity(0.14), in: Capsule())
        .overlay { if !filled { Capsule().strokeBorder(color.opacity(0.45)) } }
        .foregroundStyle(filled ? on : color)
    }

    private func save() {
        let generated = ThemeGenerator.generate(
            name: trimmedName,
            accentColor: accentColor,
            isDark: isDark,
            positiveColor: positiveOverride
        )
        try? ThemeLibrary.save(generated)
        appState.refreshCustomThemes()
        appState.theme = generated
        dismiss()
    }
}
