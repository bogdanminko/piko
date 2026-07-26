import SwiftUI

@Observable
class ModelManagerVM {
    var models: [WhisperModel] = [
        WhisperModel(id: "mlx-community/whisper-large-v3-mlx-8bit", name: "Large V3 (8-bit)", sizeMb: 1600, downloaded: false),
        WhisperModel(id: "mlx-community/whisper-large-v3-turbo", name: "Large V3 Turbo", sizeMb: 1500, downloaded: false),
        WhisperModel(id: "mlx-community/whisper-large-v3-mlx-4bit", name: "Large V3 (4-bit)", sizeMb: 900, downloaded: false),
        WhisperModel(id: "mlx-community/whisper-medium-mlx", name: "Medium", sizeMb: 1500, downloaded: false),
        WhisperModel(id: "mlx-community/whisper-tiny", name: "Tiny", sizeMb: 75, downloaded: false),
    ]
    var selectedModelId: String = "mlx-community/whisper-large-v3-mlx-8bit"
    var isDownloading: Bool = false
    var downloadMessage: String = ""

    private let backend = BackendService()

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
