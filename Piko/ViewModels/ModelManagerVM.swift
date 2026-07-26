import SwiftUI

@Observable
class ModelManagerVM {
    var models: [WhisperModel] = [
        WhisperModel(id: "mlx-community/parakeet-tdt-0.6b-v3", name: "Parakeet TDT v3",
                     sizeMb: 2300, ramMb: 1500, speed: "fast", quality: "high", downloaded: false),
        WhisperModel(id: "mlx-community/whisper-large-v3-turbo", name: "Large V3 Turbo",
                     sizeMb: 1500, ramMb: 2800, speed: "medium", quality: "high", downloaded: false),
        WhisperModel(id: "mlx-community/whisper-large-v3-mlx-8bit", name: "Large V3 (8-bit)",
                     sizeMb: 1600, ramMb: 3000, speed: "slow", quality: "high", downloaded: false)
    ]
    private static let defaultModelId = "mlx-community/parakeet-tdt-0.6b-v3"
    private static let selectedModelKey = "piko.selectedModel"

    /// Persisted: a manual choice on the Models screen survives relaunches.
    var selectedModelId: String {
        didSet { UserDefaults.standard.set(selectedModelId, forKey: Self.selectedModelKey) }
    }
    var isDownloading: Bool = false
    var downloadMessage: String = ""
    /// Model whose files are being removed right now.
    var deletingModelId: String?

    private let backend = BackendService()

    init() {
        selectedModelId = UserDefaults.standard.string(forKey: Self.selectedModelKey)
            ?? Self.defaultModelId
    }

    var selectedModel: WhisperModel? {
        models.first { $0.id == selectedModelId }
    }

    var isSelectedModelDownloaded: Bool {
        selectedModel?.downloaded ?? false
    }

    func loadModels() async {
        for await message in await backend.execute(command: "list_models") {
            if message.type == "models", let fetchedModels = message.models {
                await MainActor.run {
                    self.models = fetchedModels
                }
            }
        }
    }

    /// Delete a model's files from the HuggingFace cache. The choice of model
    /// is kept — a deleted model simply offers Download again.
    func deleteModel(_ modelId: String) async {
        await MainActor.run {
            deletingModelId = modelId
            downloadMessage = "Removing files..."
        }

        let params: [String: Any] = ["model": modelId]
        for await message in await backend.execute(command: "delete_model", params: params) {
            await MainActor.run {
                switch message.type {
                case "result" where message.success == true:
                    if let index = models.firstIndex(where: { $0.id == modelId }) {
                        models[index].downloaded = false
                    }
                    downloadMessage = message.message ?? ""
                case "error":
                    downloadMessage = message.message ?? "Could not remove the model"
                default:
                    break
                }
            }
        }

        await MainActor.run { deletingModelId = nil }
    }

    func downloadSelectedModel() async {
        await MainActor.run {
            isDownloading = true
            downloadMessage = "Starting download..."
        }

        let params: [String: Any] = ["model": selectedModelId]
        for await message in await backend.execute(command: "download_model", params: params) {
            await MainActor.run {
                if message.type == "progress" {
                    downloadMessage = message.message ?? "Downloading..."
                } else if message.type == "result", message.success == true {
                    // Mark model as downloaded
                    if let idx = models.firstIndex(where: { $0.id == selectedModelId }) {
                        models[idx].downloaded = true
                    }
                    isDownloading = false
                    downloadMessage = ""
                } else if message.type == "error" {
                    downloadMessage = message.message ?? "Download failed"
                    isDownloading = false
                }
            }
        }
    }
}
