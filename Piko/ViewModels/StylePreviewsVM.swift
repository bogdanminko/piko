import SwiftUI

/// Loads per-style preview thumbnails (sample subtitle on black),
/// rendered by the Python backend with the exact same ffmpeg pipeline
/// used for real videos.
@Observable
class StylePreviewsVM {
    var previews: [String: NSImage] = [:]

    private let backend = BackendService()

    func load() async {
        for await message in await backend.execute(command: "style_previews") {
            if message.type == "result", message.success == true,
               let paths = message.previews {
                let images = paths.compactMapValues { NSImage(contentsOfFile: $0) }
                await MainActor.run {
                    self.previews = images
                }
            }
        }
    }

    func image(for style: SubtitleStyleType) -> NSImage? {
        previews[style.rawValue]
    }
}
