import Foundation

// MARK: - Backend Command

struct BackendCommand: Encodable {
    let command: String
    let params: [String: AnyCodable]?
}

// MARK: - Backend Response Messages

struct BackendMessage: Decodable {
    let type: String
    let stage: String?
    let percent: Double?
    let message: String?
    let success: Bool?
    let outputPath: String?
    let subtitlePath: String?
    let transcriptionPath: String?
    let language: String?
    let wordCount: Int?
    let keywordsFound: Int?
    let models: [WhisperModel]?
    let code: String?
    let downloaded: Bool?
    let cached: Bool?
    let model: String?
    let style: String?
    let previews: [String: String]?
    /// Realtime progress: seconds of media handled / total ("01:20 of 03:45").
    let processedSeconds: Double?
    let totalSeconds: Double?
    /// How many local b-roll clips were cut into the render.
    let brollInserts: Int?
    /// Openly licensed candidates returned by search_broll.
    let clips: [BrollClip]?
    /// Summarizer model tiers offered for this Mac (list_llm_tiers).
    let tiers: [LLMTier]?
    let totalRamMb: Int?
    /// Tier the backend picks for this machine. The UI must not derive this:
    /// the largest tier that fits is deliberately NOT the default.
    let defaultTier: String?
    /// Sampling sliders, described by the backend so Settings hardcodes no ranges.
    let samplingControls: [SamplingControl]?
    /// Languages the summary can be written in, including the automatic option.
    let languages: [SummaryLanguage]?
    /// Whether a summarizer model is resident, and whether it is loading.
    let llm: LLMStatus?
    /// The finished meeting summary (summarize_meeting).
    let summary: MeetingSummary?
    let summaryPath: String?
    /// Live download figures, so a 12 GB fetch shows bytes and speed rather
    /// than an indeterminate bar.
    let downloadedBytes: Int?
    let bytesPerSecond: Int?

    init(type: String, stage: String? = nil, percent: Double? = nil,
         message: String? = nil, success: Bool? = nil,
         outputPath: String? = nil, subtitlePath: String? = nil,
         transcriptionPath: String? = nil, language: String? = nil,
         wordCount: Int? = nil, keywordsFound: Int? = nil,
         models: [WhisperModel]? = nil, code: String? = nil,
         downloaded: Bool? = nil, cached: Bool? = nil,
         model: String? = nil, style: String? = nil,
         previews: [String: String]? = nil,
         processedSeconds: Double? = nil, totalSeconds: Double? = nil,
         brollInserts: Int? = nil, clips: [BrollClip]? = nil,
         tiers: [LLMTier]? = nil, totalRamMb: Int? = nil,
         defaultTier: String? = nil,
         samplingControls: [SamplingControl]? = nil,
         languages: [SummaryLanguage]? = nil,
         llm: LLMStatus? = nil,
         summary: MeetingSummary? = nil, summaryPath: String? = nil,
         downloadedBytes: Int? = nil, bytesPerSecond: Int? = nil) {
        self.type = type
        self.stage = stage
        self.percent = percent
        self.message = message
        self.success = success
        self.outputPath = outputPath
        self.subtitlePath = subtitlePath
        self.transcriptionPath = transcriptionPath
        self.language = language
        self.wordCount = wordCount
        self.keywordsFound = keywordsFound
        self.models = models
        self.code = code
        self.downloaded = downloaded
        self.cached = cached
        self.model = model
        self.style = style
        self.previews = previews
        self.processedSeconds = processedSeconds
        self.totalSeconds = totalSeconds
        self.brollInserts = brollInserts
        self.clips = clips
        self.tiers = tiers
        self.totalRamMb = totalRamMb
        self.defaultTier = defaultTier
        self.samplingControls = samplingControls
        self.languages = languages
        self.llm = llm
        self.summary = summary
        self.summaryPath = summaryPath
        self.downloadedBytes = downloadedBytes
        self.bytesPerSecond = bytesPerSecond
    }

    enum CodingKeys: String, CodingKey {
        case type, stage, percent, message, success
        case outputPath = "output_path"
        case subtitlePath = "subtitle_path"
        case transcriptionPath = "transcription_path"
        case language
        case wordCount = "word_count"
        case keywordsFound = "keywords_found"
        case models, code, downloaded, cached, model, style, previews
        case processedSeconds = "processed_seconds"
        case totalSeconds = "total_seconds"
        case brollInserts = "broll_inserts"
        case clips, tiers, llm
        case totalRamMb = "total_ram_mb"
        case defaultTier = "default_tier"
        case samplingControls = "sampling_controls"
        case languages
        case summary
        case summaryPath = "summary_path"
        case downloadedBytes = "downloaded_bytes"
        case bytesPerSecond = "bytes_per_second"
    }
}

/// A language the summary can be written in. An empty code means "same as the
/// recording" — the default, so nothing has to be chosen before the first run.
struct SummaryLanguage: Codable, Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }
}

/// One sampling slider, fully described by the backend (src/piko/core/llm/sampling.py)
/// so the settings panel never hardcodes a range or a default.
struct SamplingControl: Codable, Identifiable, Hashable {
    let key: String
    let label: String
    let min: Double
    let max: Double
    let step: Double
    let `default`: Double
    /// Render as a whole number (top-k, max tokens) rather than a decimal.
    let integer: Bool
    let help: String

    var id: String { key }
}

/// One summarizer model tier (list_llm_tiers). The UI picks a tier, never a
/// repo id — the mapping lives in src/piko/core/llm/registry.py.
struct LLMTier: Codable, Identifiable, Hashable {
    let id: String
    let tier: String
    let name: String
    let sizeMb: Int
    let ramMb: Int
    let contextTokens: Int
    var downloaded: Bool
    /// False when this Mac lacks the RAM: show it greyed with the requirement
    /// rather than hiding it, so the limit is legible.
    let available: Bool

    enum CodingKeys: String, CodingKey {
        case id, tier, name, downloaded, available
        case sizeMb = "size_mb"
        case ramMb = "ram_mb"
        case contextTokens = "context_tokens"
    }
}

/// Whether the summarizer is resident, so the UI can show "warming up…".
struct LLMStatus: Codable, Hashable {
    let loaded: Bool
    let loading: Bool
    let modelKey: String?
    let matchesRequest: Bool
    let warmupError: String?

    enum CodingKeys: String, CodingKey {
        case loaded, loading
        case modelKey = "model_key"
        case matchesRequest = "matches_request"
        case warmupError = "warmup_error"
    }
}

/// One openly licensed b-roll candidate from Wikimedia Commons.
struct BrollClip: Codable, Identifiable, Hashable {
    let title: String
    let url: String
    let license: String
    let width: Int?
    let sizeMb: Double?
    /// Still-frame preview URL from Commons (jpg).
    let thumb: String?

    var id: String { url }

    enum CodingKeys: String, CodingKey {
        case title, url, license, width, thumb
        case sizeMb = "size_mb"
    }
}

struct WhisperModel: Codable, Identifiable {
    let id: String
    let name: String
    let sizeMb: Int
    let ramMb: Int
    let speed: String
    let quality: String
    var downloaded: Bool
    /// "asr" (one of them transcribes) or "speakers" (optional, runs after).
    /// Optional so a payload from a backend that predates the split decodes.
    let kind: String?

    var isSpeakerModel: Bool { kind == "speakers" }

    enum CodingKeys: String, CodingKey {
        case id, name, speed, quality, kind
        case sizeMb = "size_mb"
        case ramMb = "ram_mb"
        case downloaded
    }
}

// MARK: - Processing State

enum ProcessingState: Equatable {
    case idle
    case processing(stage: String, percent: Double, message: String)
    case done(outputPath: String, subtitlePath: String)
    case error(message: String)
}

// MARK: - AnyCodable helper

struct AnyCodable: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let string as String: try container.encode(string)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let bool as Bool: try container.encode(bool)
        default: try container.encodeNil()
        }
    }
}
