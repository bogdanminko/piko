import SwiftUI

struct ModelPickerView: View {
    @Bindable var modelManager: ModelManagerVM

    var body: some View {
        HStack(spacing: 8) {
            Picker("Model", selection: $modelManager.selectedModelId) {
                ForEach(modelManager.models) { model in
                    HStack {
                        Text(model.name)
                        if model.downloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Text("(\(model.sizeMb) MB)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .tag(model.id)
                }
            }
            .frame(width: 260)

            if !modelManager.isSelectedModelDownloaded {
                if modelManager.isDownloading {
                    ProgressView()
                        .controlSize(.small)
                    Text(modelManager.downloadMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Download") {
                        Task { await modelManager.downloadSelectedModel() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
