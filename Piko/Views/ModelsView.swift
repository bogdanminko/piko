import SwiftUI

/// Model management screen. Transcription and Summary are both real and drive
/// the view models the pipeline uses; the Alignment section is still a design
/// preview — that backend does not exist yet (see docs/PRODUCT.md).
struct ModelsView: View {
    @Bindable var modelManager: ModelManagerVM
    @Bindable var summarizer: SummarizerVM
    @Environment(\.pikoTheme) private var theme
    /// Model queued for deletion, pending confirmation.
    @State private var modelToDelete: WhisperModel?

    private struct StubModel: Identifiable {
        let id: String
        let meta: String
    }

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
                        speakersSection
                        SummarizerSection(summarizer: summarizer)
                        stubSection(label: "Caption timing", note: "word-level alignment",
                                    models: alignStubs)
                    }
                    VStack(spacing: 12) {
                        runtimeCard
                        SamplingCard(summarizer: summarizer)
                        modelsFolderCard
                    }
                    .frame(width: 300)
                }
            }
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
        .confirmationDialog(
            "Remove \(modelToDelete?.name ?? "")?",
            isPresented: Binding(get: { modelToDelete != nil },
                                 set: { if !$0 { modelToDelete = nil } }),
            presenting: modelToDelete
        ) { model in
            Button("Remove", role: .destructive) {
                Task { await modelManager.deleteModel(model.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text(deletionWarning(for: model))
        }
        // Refresh on entry: downloads and deletions change what is on disk.
        .task { await summarizer.loadTiers() }
    }

    private func deletionWarning(for model: WhisperModel) -> String {
        let freed = "Frees \(Self.formatMb(model.sizeMb)) on disk. You can download it again later."
        return model.id == modelManager.selectedModelId
            ? freed + " This is the model transcription currently uses."
            : freed
    }

    private var diskUsedDescription: String {
        let mb = modelManager.models.filter(\.downloaded).map(\.sizeMb).reduce(0, +)
        return Self.formatMb(mb)
    }

    static func formatMb(_ mb: Int) -> String {
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

                ForEach(modelManager.asrModels) { model in
                    modelRow(model)
                }

                if modelManager.isDownloading || modelManager.deletingModelId != nil {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .padding(.top, 10)
                }
                if !modelManager.downloadMessage.isEmpty {
                    Text(modelManager.downloadMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                        .padding(.top, 3)
                }
            }
        }
    }

    // MARK: - Speakers (optional)

    /// A switch, not a radio button: this model does not replace anything, it
    /// runs after transcription and only when asked. Off by default because
    /// turning it on is what authorises the download.
    @ViewBuilder
    private var speakersSection: some View {
        if let model = modelManager.speakerModel {
            ThemedCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        SectionLabel(text: "Speakers")
                        Text("who said it")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.dim)
                        Spacer()
                        Toggle("", isOn: $modelManager.identifiesSpeakers)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .padding(.bottom, 4)

                    Text("Your own voice is identified from the microphone track "
                         + "without any model. This one tells the people on the "
                         + "other side apart — up to four of them.")
                        .font(.system(size: 11.5))
                        .lineSpacing(2)
                        .foregroundStyle(theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)

                    speakerModelRow(model)

                    if modelManager.identifiesSpeakers && !model.downloaded {
                        Text("Transcripts stay side-only until this is downloaded.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.dim)
                            .padding(.top, 6)
                    }
                }
            }
        }
    }

    private func speakerModelRow(_ model: WhisperModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                Text("~\(Self.formatMb(model.ramMb)) RAM · \(model.speed.capitalized) · \(model.quality)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.dim)
            }
            Spacer(minLength: 8)

            Text(Self.formatMb(model.sizeMb))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.dim)

            if model.downloaded {
                Button {
                    modelToDelete = model
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                }
                .buttonStyle(.plain)
                .disabled(modelManager.deletingModelId != nil || modelManager.isDownloading)
                .help("Remove the downloaded files")
            } else {
                Button("Download") {
                    Task { await modelManager.download(model.id) }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(modelManager.isDownloading)
            }
        }
        .padding(.vertical, 9)
        .opacity(modelManager.identifiesSpeakers ? 1 : 0.5)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
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
            HStack(spacing: 8) {
                if isActive {
                    Text("Selected")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                } else {
                    Button("Use") { modelManager.selectedModelId = model.id }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button {
                    modelToDelete = model
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                }
                .buttonStyle(.plain)
                .disabled(modelManager.deletingModelId != nil || modelManager.isDownloading)
                .help("Remove the downloaded files")
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
                Text("Apple silicon · Whisper, Parakeet and the summarizer all on MLX")
                    .font(.system(size: 10.5))
                    .lineSpacing(2)
                    .foregroundStyle(theme.dim)
                if let totalRamMb = summarizer.totalRamMb {
                    Text("\(totalRamMb / 1024) GB unified memory")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.dim)
                }
                Rectangle().fill(theme.line).frame(height: 1)
                Text("Models load once per run and stay resident for it, so a summary "
                     + "does not reload weights for every chunk. Memory is freed when "
                     + "the run ends.")
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
