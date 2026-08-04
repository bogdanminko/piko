import SwiftUI

enum WordMode: String, CaseIterable, Identifiable {
    case `static`
    case reveal
    case highlight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .static: "Static"
        case .reveal: "Appear"
        case .highlight: "Highlight"
        }
    }

    var help: String {
        switch self {
        case .static: "Whole line shown at once"
        case .reveal: "Words appear as they are spoken"
        case .highlight: "Spoken word is tinted a color"
        }
    }
}

/// Preset colors for highlight mode (name, hex).
let highlightPalette: [(name: String, hex: String)] = [
    ("Yellow", "#FFD700"),
    ("Cyan", "#00E5FF"),
    ("Green", "#3DFF6E"),
    ("Orange", "#FF9500"),
    ("Pink", "#FF5AC8"),
    ("Red", "#FF3B30")
]

enum SubtitleStyleType: String, CaseIterable, Identifiable {
    case mrbeast
    case hormozi
    case tiktok
    case karaoke
    case minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mrbeast: "MrBeast"
        case .hormozi: "Hormozi"
        case .tiktok: "TikTok"
        case .karaoke: "Karaoke"
        case .minimal: "Minimal"
        }
    }

    /// TikTok and Karaoke animate words themselves and ignore `word_mode`
    /// entirely (see `styles/base.py`), so the control is theirs to disable.
    /// On the model rather than in a view because two screens now ask.
    var supportsWordMode: Bool {
        ![.tiktok, .karaoke].contains(self)
    }

    var description: String {
        switch self {
        case .mrbeast: "Bold Impact font, yellow keywords, thick outline"
        case .hormozi: "ALL CAPS Montserrat, cycling bright colors"
        case .tiktok: "Word-by-word highlighting with background"
        case .karaoke: "Progressive color fill as words are spoken"
        case .minimal: "Clean Helvetica, subtle italic keywords"
        }
    }

    var previewText: AttributedString {
        var base = AttributedString("This is ")
        var keyword = AttributedString("AMAZING")
        keyword.foregroundColor = accentColor
        keyword.font = .system(size: 14, weight: .bold)
        base.append(keyword)
        let end = AttributedString(" content")
        base.append(end)
        return base
    }

    var accentColor: Color {
        switch self {
        case .mrbeast: .yellow
        case .hormozi: .red
        case .tiktok: .white
        case .karaoke: .green
        case .minimal: .gray
        }
    }

    var iconName: String {
        switch self {
        case .mrbeast: "textformat.size.larger"
        case .hormozi: "bold"
        case .tiktok: "text.cursor"
        case .karaoke: "music.mic"
        case .minimal: "textformat"
        }
    }
}
