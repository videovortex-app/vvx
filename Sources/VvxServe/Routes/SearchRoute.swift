import Foundation
import Hummingbird
import VideoVortexCore

// MARK: - POST /search

struct SearchRequest: Decodable {
    let query: String
    let limit: Int?
}

struct SearchResult: Encodable {
    let videoTitle: String
    let outputPath: String
    let platform: String?
    let subtitlePath: String
    /// The matched subtitle line(s) as context.
    let matchedLines: [SRTMatch]
}

struct SRTMatch: Encodable {
    let timestamp: String   // e.g. "00:02:34,500"
    let text: String
}

/// Full-text search across .srt files in the Archive root.
/// Returns clips with timestamps and matched transcript lines.
func handleSearch(
    request: Request,
    context: some RequestContext
) async throws -> Response {
    guard let body = try? await request.body.collect(upTo: 1024 * 4),
          let decoded = try? JSONDecoder().decode(SearchRequest.self, from: Data(body.readableBytesView))
    else {
        return jsonError(status: .badRequest, message: "Invalid JSON body. Expected: {\"query\": \"...\", \"limit\": 10}")
    }

    let limit    = decoded.limit ?? 10
    let keywords = decoded.query.lowercased().split(separator: " ").map(String.init)
    guard !keywords.isEmpty else {
        return jsonError(status: .badRequest, message: "query must not be empty.")
    }

    guard let archiveRoot = MediaStoragePaths.archiveRoot() else {
        return jsonError(status: .serviceUnavailable, message: "Archive root not found.")
    }

    // Enumerate .srt files
    guard let enumerator = FileManager.default.enumerator(
        at: archiveRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return try jsonResponse([SearchResult]())
    }

    var srtFiles: [URL] = []
    while let url = enumerator.nextObject() as? URL {
        guard url.pathExtension.lowercased() == "srt",
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { continue }
        srtFiles.append(url)
    }

    var results: [SearchResult] = []

    for srtURL in srtFiles {
        guard results.count < limit else { break }
        guard let content = try? String(contentsOf: srtURL, encoding: .utf8) else { continue }

        let matches = searchSRT(content: content, keywords: keywords)
        guard !matches.isEmpty else { continue }

        // Find the corresponding video file in the same folder
        let folder = srtURL.deletingLastPathComponent()
        let videoURL = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { ["mp4", "mkv", "webm"].contains($0.pathExtension.lowercased()) }

        results.append(SearchResult(
            videoTitle: (videoURL ?? srtURL).deletingPathExtension().lastPathComponent,
            outputPath: videoURL?.path ?? folder.path,
            platform: LibraryPath.platformDisplayName(libraryRoot: archiveRoot, fileURL: srtURL),
            subtitlePath: srtURL.path,
            matchedLines: Array(matches.prefix(3))
        ))
    }

    return try jsonResponse(results)
}

// MARK: - SRT parser

private func searchSRT(content: String, keywords: [String]) -> [SRTMatch] {
    // SRT block format:
    // <index>
    // <start> --> <end>
    // <text lines...>
    // <blank line>
    var matches: [SRTMatch] = []
    let blocks = content.components(separatedBy: "\n\n")

    for block in blocks {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3 else { continue }

        // Find the timestamp line (contains " --> ")
        guard let timeLine = lines.first(where: { $0.contains("-->") }) else { continue }
        let timestamp = timeLine.components(separatedBy: " --> ").first ?? timeLine

        let textLines = lines.dropFirst(2).joined(separator: " ")
        let textLower = textLines.lowercased()

        if keywords.allSatisfy({ textLower.contains($0) }) {
            matches.append(SRTMatch(timestamp: timestamp, text: textLines))
        }
    }
    return matches
}
