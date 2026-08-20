import Foundation
import Observation

/// Drives the one-shot starter-pack download for the b-roll library.
@Observable
final class BRollPackVM {
    var isDownloading = false
    var statusMessage = ""
    /// Candidates from the last search, shown as download buttons.
    var searchResults: [BrollClip] = []

    private let backend = BackendService()

    func downloadPack() async {
        await run(command: "download_broll_pack", params: nil)
    }

    /// Keyless Wikimedia Commons search: fills searchResults for the UI.
    func search(query: String) async {
        await MainActor.run {
            isDownloading = true
            statusMessage = "Searching Wikimedia Commons..."
            searchResults = []
        }
        for await message in await backend.execute(command: "search_broll",
                                                   params: ["query": query]) {
            await MainActor.run {
                switch message.type {
                case "result" where message.success == true:
                    searchResults = message.clips ?? []
                    statusMessage = searchResults.isEmpty
                        ? "Nothing openly licensed found — try another query"
                        : ""
                    isDownloading = false
                case "error":
                    statusMessage = message.message ?? "Search failed"
                    isDownloading = false
                default:
                    break
                }
            }
        }
        await MainActor.run { isDownloading = false }
    }

    /// Download one picked candidate; the backend records its license.
    func download(clip: BrollClip, concept: String) async {
        await run(command: "fetch_broll", params: [
            "concept": concept,
            "url": clip.url,
            "title": clip.title,
            "license": clip.license
        ])
    }

    private func run(command: String, params: [String: Any]?) async {
        await MainActor.run {
            isDownloading = true
            statusMessage = "Starting..."
        }
        for await message in await backend.execute(command: command, params: params) {
            await MainActor.run {
                switch message.type {
                case "progress":
                    statusMessage = message.message ?? "Working..."
                case "result" where message.success == true:
                    statusMessage = message.message ?? "Done"
                    isDownloading = false
                case "error":
                    statusMessage = message.message ?? "Failed"
                    isDownloading = false
                default:
                    break
                }
            }
        }
        await MainActor.run { isDownloading = false }
    }
}
