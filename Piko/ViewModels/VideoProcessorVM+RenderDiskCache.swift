import Foundation

/// Persistence for finished renders: the output path encodes every setting,
/// so a file on disk from a previous session can be reused without ffmpeg.
extension VideoProcessorVM {
    /// keywords_found per output path, persisted so a disk-cache hit from a
    /// past session can restore the stats badge.
    static let renderMetaKey = "piko.renderMeta"

    static func rememberKeywords(_ count: Int, for outputPath: String) {
        var meta = UserDefaults.standard.dictionary(forKey: renderMetaKey) as? [String: Int] ?? [:]
        meta[outputPath] = count
        UserDefaults.standard.set(meta, forKey: renderMetaKey)
    }

    /// A finished render from a previous session, if it is still on disk
    /// together with its .ass and not older than the source video.
    static func diskRender(outputPath: String, subtitlePath: String,
                           source: URL) -> RenderResult? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: outputPath), fm.fileExists(atPath: subtitlePath) else {
            return nil
        }
        func mtime(_ path: String) -> Date {
            (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date ?? .distantPast)
                ?? .distantPast
        }
        guard mtime(outputPath) >= mtime(source.path) else { return nil }
        let meta = UserDefaults.standard.dictionary(forKey: renderMetaKey) as? [String: Int]
        return RenderResult(outputPath: outputPath,
                            subtitlePath: subtitlePath,
                            keywordsFound: meta?[outputPath] ?? 0)
    }

    /// Looks up a cached render (in-memory, falling back to disk) and, if
    /// found, adopts it as the current result. Returns whether it served.
    func serveFromCache(outputPath: String, subtitlePath: String, source: URL) -> Bool {
        let cached = renderCache[outputPath]
            ?? Self.diskRender(outputPath: outputPath, subtitlePath: subtitlePath, source: source)
        guard let cached, FileManager.default.fileExists(atPath: cached.outputPath) else {
            return false
        }
        outputURL = URL(fileURLWithPath: cached.outputPath)
        subtitleURL = URL(fileURLWithPath: cached.subtitlePath)
        keywordsFound = cached.keywordsFound
        renderCache[outputPath] = cached
        state = .done(outputPath: cached.outputPath, subtitlePath: cached.subtitlePath)
        onRenderCompleted?()
        return true
    }
}
