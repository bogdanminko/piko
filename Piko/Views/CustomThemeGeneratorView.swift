import SwiftUI

/// Sheet for generating a custom theme from a single accent color plus a
/// light/dark choice — Piko derives the rest of the token set
/// (`ThemeGenerator.generate`) and shows it live before Save writes it to
/// the Themes folder as a `.piko-theme.json` file.
struct CustomThemeGeneratorView: View {
    @Bindable var appState: AppState
    @Environment(\.pikoTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var accentColor = Color(hex: "8AADF4")
    @State private var isDark = true
    @State private var name = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var preview: ThemeTokens {
        ThemeGenerator.generate(
            name: trimmedName.isEmpty ? "Custom" : trimmedName,
            accentColor: accentColor,
            isDark: isDark
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

    private func save() {
        let generated = ThemeGenerator.generate(name: trimmedName, accentColor: accentColor, isDark: isDark)
        try? ThemeLibrary.save(generated)
        appState.refreshCustomThemes()
        appState.theme = generated
        dismiss()
    }
}
