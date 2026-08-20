import SwiftUI

/// Summarizer model state for the Models screen.
///
/// The tier list, its RAM requirements and the sampling ranges all come from
/// the backend (`list_llm_tiers` → src/piko/core/llm/registry.py and
/// sampling.py). Nothing here hardcodes a model id or a slider range, so
/// swapping a tier's underlying model never touches this file.
@Observable
class SummarizerVM {
    /// Tiers offered for this Mac. Empty until the first load.
    var tiers: [LLMTier] = []
    /// Slider descriptions the settings panel renders.
    var samplingControls: [SamplingControl] = []
    /// Offered summary languages, first entry being "same as the recording".
    var languages: [SummaryLanguage] = []
    var totalRamMb: Int?
    /// The backend's pick for this machine. Shown as "default" in the list so
    /// a user who changed tiers can find their way back.
    var backendDefaultTier = ""

    var isDownloading = false
    var downloadingTier: String?
    /// 0...1 for the bar. Nil while the size is still unknown.
    var downloadProgress: Double?
    var statusMessage = ""
    /// Whether a model is resident, so the UI can say "ready" and not just "downloaded".
    var isWarm = false
    var isWarming = false

    /// Versioned, and bumped whenever a tier name changes meaning — a stored
    /// name that now points at a different model would silently switch the
    /// user's model. v2 dropped values from a build that defaulted to the
    /// largest tier that fits; v3 follows "quality" moving from the 20B MoE to
    /// the dense 9B.
    private static let selectedTierKey = "piko.summarizer.tier.v3"
    private static let samplingKey = "piko.summarizer.sampling"
    private static let languageKey = "piko.summarizer.language"

    /// Persisted: a choice on the Models screen survives relaunches. Empty
    /// means "let the backend pick for this machine's RAM".
    var selectedTier: String {
        didSet { UserDefaults.standard.set(selectedTier, forKey: Self.selectedTierKey) }
    }

    /// Sampling overrides, keyed by control id. Only non-default values are stored.
    var sampling: [String: Double] {
        didSet { UserDefaults.standard.set(sampling, forKey: Self.samplingKey) }
    }

    /// Language to write the summary in. Empty means "same as the recording",
    /// which lets the backend detect it — the zero-setup default.
    var outputLanguage: String {
        didSet { UserDefaults.standard.set(outputLanguage, forKey: Self.languageKey) }
    }

    private let backend = BackendService()

    init() {
        selectedTier = UserDefaults.standard.string(forKey: Self.selectedTierKey) ?? ""
        sampling = UserDefaults.standard.dictionary(forKey: Self.samplingKey) as? [String: Double]
            ?? [:]
        outputLanguage = UserDefaults.standard.string(forKey: Self.languageKey) ?? ""
    }

    var selected: LLMTier? {
        tiers.first { $0.tier == selectedTier } ?? tiers.first { $0.available && $0.downloaded }
    }

    /// Params every summarize call should carry: which model, and how to sample.
    var requestParams: [String: Any] {
        var params: [String: Any] = [:]
        if !selectedTier.isEmpty { params["tier"] = selectedTier }
        if !sampling.isEmpty { params["sampling"] = sampling }
        if !outputLanguage.isEmpty { params["output_language"] = outputLanguage }
        return params
    }

    /// Whether a summarizer model is on disk at all. The workspace chat asks,
    /// so it can say "not downloaded yet" instead of failing silently when a
    /// question reaches a model that was never fetched.
    var isModelDownloaded: Bool {
        selected?.downloaded ?? tiers.contains { $0.downloaded }
    }

    /// Whether the weights are resident, and how long they took to get there.
    /// The workspace shows both, because "this answer was written ahead of
    /// time and the model is still loading" is only an honest thing to say if
    /// the moment it stops being true is visible.
    private(set) var isModelWarm = false
    private(set) var warmupSeconds: Double?
    /// Whether *something* is in memory, whatever tier it is.
    ///
    /// Different from `isModelWarm`, which means "ready for what you would ask
    /// right now". Change the tier and the old weights stay resident until the
    /// next request swaps them or the idle sweeper drops them — so a card that
    /// only knew about `isModelWarm` went blank and hid its Eject button while
    /// gigabytes were still held, which is precisely the moment somebody wants
    /// that button.
    private(set) var isModelResident = false
    /// The resident tier when it is *not* the chosen one, so the card can say
    /// whose memory this is.
    private(set) var residentTier: String?
    /// What the backend process is holding right now, reported by MLX. Nil
    /// when nothing is resident.
    private(set) var residentBytes: Int?
    /// Seconds since the model last did any work, and how long it may idle
    /// before it releases itself.
    private(set) var idleSeconds: Double?
    private(set) var releasesAfter: Double?
    /// A warmup already in flight, so two callers do not both poll.
    @ObservationIgnored private var warmupInFlight = false

    /// Start loading the model without waiting for it.
    ///
    /// Fired the moment the user asks the opening question, so the seconds
    /// spent reading the written answer are the same seconds the weights
    /// spend becoming resident. A failure only leaves `isModelWarm` false:
    /// this is an optimisation, and the request that needs the model reports
    /// its own errors.
    func warmup() {
        guard isModelDownloaded, !isModelWarm, !warmupInFlight else { return }
        warmupInFlight = true
        let params = requestParams
        let started = Date()
        Task { [backend] in
            for await _ in await backend.execute(command: "warmup_llm", params: params) {}
            // `warmup_llm` starts a background load and returns at once, so the
            // status in its own reply is always "not loaded yet". Reading it as
            // the answer is what made the workspace claim "model up in 0.3 s"
            // for a model that had not finished loading — and, before the
            // process was resident, for one that no longer existed at all.
            while true {
                let status = await Self.status(from: backend, params: params)
                if let status, !status.loading {
                    await MainActor.run {
                        self.apply(status)
                        self.warmupSeconds = status.loaded
                            ? Date().timeIntervalSince(started) : nil
                        self.warmupInFlight = false
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Ask the backend what it is holding.
    func refreshStatus() {
        let params = requestParams
        Task { [backend] in
            let status = await Self.status(from: backend, params: params)
            await MainActor.run { self.apply(status) }
        }
    }

    /// Hand the memory back now.
    ///
    /// Two steps, and both are needed: `release_llm` frees the weights inside
    /// the process, and taking the process down as well is what makes the
    /// button honest — a resident Python that has merely forgotten its model is
    /// still a resident Python, and the next request would quietly reload
    /// anyway. The following message starts a fresh one and pays the load once.
    func eject() {
        let params = requestParams
        Task { [backend] in
            for await _ in await backend.execute(command: "release_llm", params: params) {}
            await BackendService.ejectModel()
            await MainActor.run {
                self.isModelWarm = false
                self.isModelResident = false
                self.residentTier = nil
                self.warmupSeconds = nil
                self.residentBytes = nil
                self.idleSeconds = nil
            }
        }
    }

    private static func status(from backend: BackendService,
                               params: [String: Any]) async -> LLMStatus? {
        for await message in await backend.execute(command: "llm_status", params: params) {
            if message.type == "result", let llm = message.llm { return llm }
        }
        return nil
    }

    private func apply(_ status: LLMStatus?) {
        let loaded = status?.loaded == true
        isModelResident = loaded
        isModelWarm = loaded && status?.matchesRequest == true
        // "mlx:balanced" → "balanced"; nil when it is the tier you asked for,
        // because naming it then would be noise.
        residentTier = loaded && status?.matchesRequest != true
            ? status?.modelKey?.split(separator: ":").last.map(String.init)
            : nil
        residentBytes = loaded ? status?.activeBytes : nil
        idleSeconds = loaded ? status?.idleSeconds : nil
        releasesAfter = status?.releasesAfter
        if !isModelWarm { warmupSeconds = nil }
    }

    /// True when the stored value differs from the backend's default.
    func isCustomised(_ control: SamplingControl) -> Bool {
        guard let value = sampling[control.key] else { return false }
        return abs(value - control.default) > 0.0001
    }

    func value(for control: SamplingControl) -> Double {
        sampling[control.key] ?? control.default
    }

    func setValue(_ value: Double, for control: SamplingControl) {
        if abs(value - control.default) < 0.0001 {
            sampling.removeValue(forKey: control.key)
        } else {
            sampling[control.key] = value
        }
    }

    func resetSampling() {
        sampling = [:]
    }

    func loadTiers() async {
        for await message in await backend.execute(command: "list_llm_tiers") {
            guard message.type == "tiers", let fetched = message.tiers else { continue }
            await MainActor.run {
                self.tiers = fetched
                self.samplingControls = message.samplingControls ?? []
                self.languages = message.languages ?? []
                self.totalRamMb = message.totalRamMb
                self.backendDefaultTier = message.defaultTier ?? ""
                // Take the backend's pick when nothing is stored, or when a
                // saved tier no longer fits this machine. Never "the largest
                // that fits" — the biggest tier is opt-in, not a default.
                if !fetched.contains(where: { $0.tier == self.selectedTier && $0.available }) {
                    self.selectedTier = message.defaultTier ?? ""
                }
            }
        }
    }

    func download(_ tier: LLMTier) async {
        await MainActor.run {
            isDownloading = true
            downloadingTier = tier.tier
            downloadProgress = nil
            statusMessage = "Starting download..."
        }

        for await message in await backend.execute(command: "download_llm_model",
                                                   params: ["tier": tier.tier]) {
            await MainActor.run {
                switch message.type {
                case "progress":
                    statusMessage = message.message ?? "Downloading..."
                    if let percent = message.percent, percent > 0 {
                        downloadProgress = percent / 100
                    }
                case "result" where message.success == true:
                    if let index = tiers.firstIndex(where: { $0.tier == tier.tier }) {
                        tiers[index].downloaded = true
                    }
                    statusMessage = ""
                case "error":
                    statusMessage = message.message ?? "Download failed"
                default:
                    break
                }
            }
        }

        await MainActor.run {
            isDownloading = false
            downloadingTier = nil
            downloadProgress = nil
        }
    }

    func delete(_ tier: LLMTier) async {
        await MainActor.run { statusMessage = "Removing files..." }

        for await message in await backend.execute(command: "delete_model",
                                                   params: ["model": tier.id]) {
            await MainActor.run {
                switch message.type {
                case "result" where message.success == true:
                    if let index = tiers.firstIndex(where: { $0.tier == tier.tier }) {
                        tiers[index].downloaded = false
                    }
                    statusMessage = message.message ?? ""
                case "error":
                    statusMessage = message.message ?? "Could not remove the model"
                default:
                    break
                }
            }
        }
    }
}
