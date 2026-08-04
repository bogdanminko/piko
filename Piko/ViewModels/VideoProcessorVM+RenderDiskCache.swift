import Foundation

/// Persistence for finished renders: the output path encodes every setting,
/// so a file on disk from a previous session can be reused without ffmpeg.
extension VideoProcessorVM {
    /// keywords_found per output path, persisted so a disk-cache hit from a
    /// past session can restore the stats badge.
    static let renderMetaKey = "piko.renderMeta"

    /// The cache key, spelled as a file-name suffix: every setting that can
    /// change the picture has to appear here, or a stale render answers for
    /// the new one.
    func renderSuffix(style: String) -> String {
        var suffix = "_subtitled_\(style)"
        if wordMode != .static {
            suffix += "_\(wordMode.rawValue)"
            if wordMode == .highlight {
                suffix += "_\(highlightColorHex.dropFirst().lowercased())"
            }
        }
        if brollEnabled {
            suffix += "_broll"
        }
        // Corrections change the picture too. Without them in the key, fixing
        // a misheard name would hit the render made before the fix, and the
        // correction would appear to do nothing at all.
        if let fingerprint = transcript?.textFingerprint, !edits.edits.isEmpty {
            suffix += "_e\(fingerprint)"
        }
        return suffix
    }

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

    // MARK: - Cache management

    /// Total size of the app cache (transcriptions, renders, emoji, previews).
    static func cacheSizeDescription() -> String {
        let fm = FileManager.default
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: cacheDir,
                                          includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let file as URL in enumerator {
                let size = (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0
                total += Int64(size)
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// Wipe the whole app cache. Unsaved renders and cached transcriptions
    /// are gone after this, so the session falls back to the pre-render state.
    ///
    /// Corrections are deliberately untouched: they live in Application
    /// Support because they were typed by hand, and this button throws away
    /// only what can be recomputed.
    func clearCache() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: Self.cacheDir,
                                                   includingPropertiesForKeys: nil) {
            for item in items {
                try? fm.removeItem(at: item)
            }
        }
        renderCache = [:]
        transcriptionPath = nil
        transcript = nil
        outputURL = nil
        subtitleURL = nil
        srtURL = nil
        vttURL = nil
        UserDefaults.standard.removeObject(forKey: Self.renderMetaKey)
        switch state {
        case .done, .transcribed:
            state = .idle
        default:
            break
        }
    }
}
