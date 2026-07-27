import SwiftUI

@Observable
class ModelManagerVM {
    var models: [WhisperModel] = [
        WhisperModel(id: "mlx-community/parakeet-tdt-0.6b-v3", name: "Parakeet TDT v3",
                     sizeMb: 2300, ramMb: 1296, speed: "fast", quality: "high",
                     downloaded: false, kind: "asr"),
        WhisperModel(id: "mlx-community/whisper-large-v3-turbo", name: "Large V3 Turbo",
                     sizeMb: 1500, ramMb: 1614, speed: "medium", quality: "high",
                     downloaded: false, kind: "asr"),
        WhisperModel(id: "mlx-community/whisper-large-v3-mlx-8bit", name: "Large V3 (8-bit)",
                     sizeMb: 1600, ramMb: 1720, speed: "slow", quality: "high",
                     downloaded: false, kind: "asr"),
        WhisperModel(id: "mlx-community/diar_sortformer_4spk-v1-fp16",
                     name: "Sortformer 4-speaker",
                     sizeMb: 236, ramMb: 248, speed: "fast", quality: "up to 4 voices",
                     downloaded: false, kind: "speakers")
    ]
    private static let defaultModelId = "mlx-community/parakeet-tdt-0.6b-v3"
    private static let selectedModelKey = "piko.selectedModel"
    private static let identifySpeakersKey = "piko.identifySpeakers"

    /// Persisted: a manual choice on the Models screen survives relaunches.
    var selectedModelId: String {
        didSet { UserDefaults.standard.set(selectedModelId, forKey: Self.selectedModelKey) }
    }
    /// Persisted, and off by default: turning it on is what authorises the
    /// 236 MB download and ~1 GB of extra peak memory. The Models screen
    /// promises nothing downloads until asked, and this is the asking.
    var identifiesSpeakers: Bool {
        didSet { UserDefaults.standard.set(identifiesSpeakers, forKey: Self.identifySpeakersKey) }
    }
    var isDownloading: Bool = false
    var downloadMessage: String = ""
    /// Model whose files are being removed right now.
    var deletingModelId: String?

    private let backend = BackendService()

    init() {
        selectedModelId = UserDefaults.standard.string(forKey: Self.selectedModelKey)
            ?? Self.defaultModelId
        identifiesSpeakers = UserDefaults.standard.bool(forKey: Self.identifySpeakersKey)
    }

    /// The transcribers — exactly one of these runs, chosen by radio button.
    var asrModels: [WhisperModel] { models.filter { !$0.isSpeakerModel } }

    /// The optional speaker model, if the backend offers one.
    var speakerModel: WhisperModel? { models.first { $0.isSpeakerModel } }

    /// Diarization can only run once its model is on disk, so the switch being
    /// on is not enough — this is what the pipeline is actually gated on.
    var diarizationReady: Bool { identifiesSpeakers && (speakerModel?.downloaded ?? false) }

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
        await download(selectedModelId)
    }

    /// Fetch any model in the list — the speaker model is downloaded the same
    /// way as a transcriber, just from a different row.
    func download(_ modelId: String) async {
        await MainActor.run {
            isDownloading = true
            downloadMessage = "Starting download..."
        }

        let params: [String: Any] = ["model": modelId]
        for await message in await backend.execute(command: "download_model", params: params) {
            await MainActor.run {
                if message.type == "progress" {
                    downloadMessage = message.message ?? "Downloading..."
                } else if message.type == "result", message.success == true {
                    // Mark model as downloaded
                    if let idx = models.firstIndex(where: { $0.id == modelId }) {
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
