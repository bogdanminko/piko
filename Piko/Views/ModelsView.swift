import SwiftUI

/// Model management screen. The Transcription section is real and drives
/// the same ModelManagerVM the pipeline uses; Summary and Alignment models
/// and the active-models strip are design previews — those backends don't
/// exist yet (see docs/PRODUCT.md).
struct ModelsView: View {
    @Bindable var modelManager: ModelManagerVM
    @Environment(\.pikoTheme) private var theme

    private struct StubModel: Identifiable {
        let id: String
        let meta: String
    }

    private let summaryStubs = [
        StubModel(id: "qwen3.6-4b-instruct", meta: "4B parameters · 4-bit · ~2.3 GB on disk"),
        StubModel(id: "qwen3.6-2b-instruct", meta: "2B parameters · 4-bit · ~1.2 GB on disk"),
        StubModel(id: "gpt-oss-20b", meta: "20B parameters (MoE) · MXFP4 · ~12 GB on disk"),
        StubModel(id: "piko-slm-4b", meta: "4B parameters · Piko's own SLM · in development"),
        StubModel(id: "piko-slm-2b", meta: "2B parameters · Piko's own SLM · in development")
    ]
    private let alignStubs = [
        StubModel(id: "piko-align-80m", meta: "80M parameters · FP16 · 160 MB on disk"),
        StubModel(id: "piko-align-320m", meta: "320M parameters · FP16 · 640 MB on disk")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: "Models",
                         subtitle: "Nothing downloads in the background — you pick a model and press Download yourself.") {
                Text("\(diskUsedDescription) on disk")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.dim)
            }
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 12) {
                        transcriptionSection
                        stubSection(label: "Summary and decisions", note: "text → structure",
                                    models: summaryStubs)
                        stubSection(label: "Caption timing", note: "word-level alignment",
                                    models: alignStubs)
                    }
                    VStack(spacing: 12) {
                        runtimeCard
                        modelsFolderCard
                    }
                    .frame(width: 300)
                }
            }
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
    }

    private var diskUsedDescription: String {
        let mb = modelManager.models.filter(\.downloaded).map(\.sizeMb).reduce(0, +)
        return Self.formatMb(mb)
    }

    private static func formatMb(_ mb: Int) -> String {
        mb >= 1000
            ? String(format: "%.1f GB", Double(mb) / 1000)
            : "\(mb) MB"
    }

    // MARK: - Transcription (real)

    private var transcriptionSection: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    SectionLabel(text: "Transcription")
                    Text("speech → text")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                    Spacer()
                    Text(modelManager.selectedModel?.name ?? "—")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.text)
                }
                .padding(.bottom, 4)

                ForEach(modelManager.models) { model in
                    modelRow(model)
                }

                if modelManager.isDownloading {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .padding(.top, 10)
                    Text(modelManager.downloadMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                        .padding(.top, 3)
                }
            }
        }
    }

    private func modelRow(_ model: WhisperModel) -> some View {
        let isActive = modelManager.selectedModelId == model.id
        return HStack(spacing: 12) {
            Circle()
                .strokeBorder(isActive ? theme.accent : theme.dim,
                              lineWidth: isActive ? 4 : 1.5)
                .frame(width: 13, height: 13)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                Text("~\(Self.formatMb(model.ramMb)) RAM · \(model.speed.capitalized) · \(model.quality.capitalized) quality")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.dim)
            }
            Spacer(minLength: 8)

            Text(Self.formatMb(model.sizeMb))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.dim)
            actionButton(for: model, isActive: isActive)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    @ViewBuilder
    private func actionButton(for model: WhisperModel, isActive: Bool) -> some View {
        if model.downloaded {
            if isActive {
                Text("Selected")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.dim)
                    .padding(.horizontal, 12)
            } else {
                Button("Use") { modelManager.selectedModelId = model.id }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            Button("Download") {
                modelManager.selectedModelId = model.id
                Task { await modelManager.downloadSelectedModel() }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(modelManager.isDownloading)
        }
    }

    private func statusChip(_ text: String, outlined: Bool) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(outlined ? Color.clear : theme.card2, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                if outlined {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(theme.line)
                }
            }
            .foregroundStyle(outlined ? theme.dim : theme.text)
    }

    // MARK: - Stub sections (backends not implemented)

    private func stubSection(label: String, note: String, models: [StubModel]) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    SectionLabel(text: label)
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                    Spacer()
                    ComingSoonBadge()
                }
                .padding(.bottom, 4)

                ForEach(models) { model in
                    HStack(spacing: 12) {
                        Circle()
                            .strokeBorder(theme.dim, lineWidth: 1.5)
                            .frame(width: 13, height: 13)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.id)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.text)
                            Text(model.meta)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(theme.dim)
                        }
                        Spacer(minLength: 8)
                        statusChip("planned", outlined: true)
                    }
                    .padding(.vertical, 9)
                    .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
                }
            }
            .opacity(0.6)
        }
    }

    // MARK: - Right column

    private var runtimeCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 11) {
                SectionLabel(text: "Runtime")
                HStack(spacing: 8) {
                    Circle().fill(theme.positive).frame(width: 7, height: 7)
                    Text("Embedded MLX · Metal")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.text)
                }
                Text("Apple silicon · unified memory")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.dim)
                Rectangle().fill(theme.line).frame(height: 1)
                Text("Each command runs as a short-lived process — models load for the "
                     + "duration of a run and memory is freed right after.")
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(theme.dim)
            }
        }
    }

    private var modelsFolderCard: some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Models folder")
                    Spacer()
                    ComingSoonBadge()
                }
                Text("MLX has its own quantized weight format — Piko's runtime is "
                     + "Apple-native end to end, no GGUF or llama.cpp involved. "
                     + "Downloaded models will be listed here.")
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(theme.dim)
            }
        }
    }
}
