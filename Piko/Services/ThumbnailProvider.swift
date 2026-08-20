import AppKit
import AVFoundation
import SwiftUI

/// Async video thumbnails (frame at ~1s) with an in-memory cache.
@MainActor
enum ThumbnailProvider {
    private static var cache: [String: NSImage] = [:]

    static func thumbnail(for path: String) async -> NSImage? {
        if let hit = cache[path] { return hit }
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }

        let image = NSImage(cgImage: cgImage, size: .zero)
        cache[path] = image
        return image
    }
}

/// Small video preview: real frame when loadable, film glyph otherwise.
/// Size comes from the caller's .frame().
struct VideoThumbView: View {
    let path: String
    var cornerRadius: CGFloat = 4

    @State private var image: NSImage?
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        ZStack {
            if let image {
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
            } else {
                theme.card2
                Image(systemName: "film")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.dim)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: path) {
            image = await ThumbnailProvider.thumbnail(for: path)
        }
    }
}
