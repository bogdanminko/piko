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

    init(type: String, stage: String? = nil, percent: Double? = nil,
         message: String? = nil, success: Bool? = nil,
         outputPath: String? = nil, subtitlePath: String? = nil,
         transcriptionPath: String? = nil, language: String? = nil,
         wordCount: Int? = nil, keywordsFound: Int? = nil,
         models: [WhisperModel]? = nil, code: String? = nil,
         downloaded: Bool? = nil, cached: Bool? = nil,
         model: String? = nil, style: String? = nil,
         previews: [String: String]? = nil) {
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
    }
}

struct WhisperModel: Codable, Identifiable {
    let id: String
    let name: String
    let sizeMb: Int
    var downloaded: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case sizeMb = "size_mb"
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
        if let v = value as? String { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Double { try container.encode(v) }
        else if let v = value as? Bool { try container.encode(v) }
        else { try container.encodeNil() }
    }
}
