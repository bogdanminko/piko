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
