import Foundation

/// Reads and writes `.piko-theme.json` files in the user's Themes folder —
/// the save target for the custom-theme generator and the drop-in target
/// for a hand-authored or shared theme file.
enum ThemeLibrary {
    static let themesFolder = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Piko/Themes", isDirectory: true)

    private static let suffix = ".piko-theme.json"

    /// Skips any file that fails to decode or doesn't carry every token
    /// Piko needs — a broken file is never applied and never crashes Piko.
    static func loadCustomThemes() -> [ThemeTokens] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: themesFolder, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        return urls
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .compactMap { url -> ThemeTokens? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return (try? decoder.decode(ThemeFile.self, from: data))?.tokens
            }
    }

    static func save(_ theme: ThemeTokens) throws {
        try FileManager.default.createDirectory(at: themesFolder, withIntermediateDirectories: true)
        let slug = theme.displayName
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let filename = "\(slug.isEmpty ? "theme" : slug)-\(theme.id.prefix(8))\(suffix)"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ThemeFile(theme))
        try data.write(to: themesFolder.appendingPathComponent(filename))
    }

    /// Removes the file backing a custom theme, matched by the `id` stored
    /// inside it rather than by filename — filenames aren't guaranteed
    /// stable if a user renamed the file by hand.
    static func delete(_ theme: ThemeTokens) throws {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: themesFolder, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        for url in urls where url.lastPathComponent.hasSuffix(suffix) {
            guard let data = try? Data(contentsOf: url),
                  let file = try? decoder.decode(ThemeFile.self, from: data),
                  file.id == theme.id
            else { continue }
            try FileManager.default.removeItem(at: url)
            return
        }
    }
}
