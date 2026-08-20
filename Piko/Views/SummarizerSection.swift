import SwiftUI

/// Summarizer tiers on the Models screen.
///
/// Every row comes from `list_llm_tiers` — the tier registry lives in
/// src/piko/core/llm/registry.py and nothing here names a model. A tier the
/// machine cannot run stays visible but greyed with its RAM requirement, so
/// the limit is legible rather than mysterious.
struct SummarizerSection: View {
    @Bindable var summarizer: SummarizerVM
    @Environment(\.pikoTheme) private var theme
    @State private var tierToDelete: LLMTier?

    var body: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    SectionLabel(text: "Summary and decisions")
                    Text("text → structure")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                    Spacer()
                    Text(summarizer.selected?.name ?? "—")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.text)
                }
                .padding(.bottom, 4)

                ForEach(summarizer.tiers) { tier in
                    row(tier)
                }

                if summarizer.isDownloading {
                    // Determinate as soon as the backend knows the size: a
                    // 12 GB download behind an indeterminate bar is
                    // indistinguishable from one that has hung.
                    ProgressView(value: summarizer.downloadProgress ?? 0, total: 1)
                        .progressViewStyle(.linear)
                        .opacity(summarizer.downloadProgress == nil ? 0.4 : 1)
                        .padding(.top, 10)
                }
                if !summarizer.statusMessage.isEmpty {
                    HStack {
                        Text(summarizer.statusMessage)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.dim)
                        Spacer()
                        if let progress = summarizer.downloadProgress {
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.text)
                        }
                    }
                    .padding(.top, 3)
                }
            }
        }
        .confirmationDialog(
            "Remove \(tierToDelete?.name ?? "")?",
            isPresented: Binding(get: { tierToDelete != nil },
                                 set: { if !$0 { tierToDelete = nil } }),
            presenting: tierToDelete
        ) { tier in
            Button("Remove", role: .destructive) {
                Task { await summarizer.delete(tier) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { tier in
            Text("Frees \(ModelsView.formatMb(tier.sizeMb)) on disk. "
                 + "You can download it again later.")
        }
    }

    private func row(_ tier: LLMTier) -> some View {
        let isActive = summarizer.selectedTier == tier.tier
        return HStack(spacing: 12) {
            Circle()
                .strokeBorder(isActive ? theme.accent : theme.dim,
                              lineWidth: isActive ? 4 : 1.5)
                .frame(width: 13, height: 13)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tier.name)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.text)
                    if tier.tier == summarizer.backendDefaultTier {
                        Text("default")
                            .font(.system(size: 9.5))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(theme.card2, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(theme.dim)
                    }
                }
                Text(meta(tier))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.dim)
            }
            Spacer(minLength: 8)

            Text(ModelsView.formatMb(tier.sizeMb))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.dim)
            action(tier, isActive: isActive)
        }
        .padding(.vertical, 9)
        .opacity(tier.available ? 1 : 0.45)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    /// On a small Mac the RAM line is the whole story, so it leads.
    private func meta(_ tier: LLMTier) -> String {
        let context = "\(tier.contextTokens / 1024)K context"
        guard tier.available else {
            return "needs \(tier.ramMb / 1024) GB of RAM · \(context)"
        }
        return "~\(ModelsView.formatMb(tier.ramMb)) RAM · \(context)"
    }

    @ViewBuilder
    private func action(_ tier: LLMTier, isActive: Bool) -> some View {
        if !tier.available {
            Text("too large")
                .font(.system(size: 10.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(theme.line) }
                .foregroundStyle(theme.dim)
        } else if tier.downloaded {
            HStack(spacing: 8) {
                if isActive {
                    Text("Selected")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                } else {
                    Button("Use") { summarizer.selectedTier = tier.tier }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button { tierToDelete = tier } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                }
                .buttonStyle(.plain)
                .disabled(summarizer.isDownloading)
                .help("Remove the downloaded files")
            }
        } else {
            Button("Download") {
                summarizer.selectedTier = tier.tier
                Task { await summarizer.download(tier) }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(summarizer.isDownloading)
        }
    }
}

/// Sampling sliders, built entirely from what the backend reports.
///
/// Ranges, steps, defaults and help text all come from `sampling_controls`
/// (src/piko/core/llm/sampling.py), so adding a knob there makes it appear
/// here without a Swift change — and the two sides cannot disagree about what
/// a value means. Collapsed by default: the greedy defaults are correct for
/// summarization and most people should never open this.
struct SamplingCard: View {
    @Bindable var summarizer: SummarizerVM
    @Environment(\.pikoTheme) private var theme
    @State private var isExpanded = false

    var body: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 11) {
                header
                Text(summary)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(theme.dim)

                if isExpanded {
                    Rectangle().fill(theme.line).frame(height: 1)
                    ForEach(summarizer.samplingControls) { control in
                        row(control)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            SectionLabel(text: "Sampling")
            Spacer()
            if customisedCount > 0 {
                Button("Reset") { summarizer.resetSampling() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accent)
            }
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.dim)
            }
            .buttonStyle(.plain)
        }
    }

    private var summary: String {
        guard customisedCount > 0 else {
            return "Defaults are greedy — summaries stay faithful to the transcript."
        }
        return "\(customisedCount) setting\(customisedCount == 1 ? "" : "s") "
            + "changed from the default."
    }

    private var customisedCount: Int {
        summarizer.samplingControls.filter(summarizer.isCustomised).count
    }

    private func row(_ control: SamplingControl) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(control.label)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
                Spacer()
                Text(formatted(summarizer.value(for: control), control: control))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(summarizer.isCustomised(control) ? theme.accent : theme.dim)
            }
            Slider(
                value: Binding(
                    get: { summarizer.value(for: control) },
                    set: { summarizer.setValue($0, for: control) }
                ),
                in: control.min...control.max,
                step: control.step
            )
            .controlSize(.mini)
            Text(control.help)
                .font(.system(size: 10))
                .lineSpacing(1)
                .foregroundStyle(theme.dim)
        }
        .padding(.vertical, 4)
    }

    private func formatted(_ value: Double, control: SamplingControl) -> String {
        control.integer ? String(Int(value)) : String(format: "%.2f", value)
    }
}
