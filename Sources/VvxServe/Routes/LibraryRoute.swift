import Foundation
import Hummingbird
import VideoVortexCore

// MARK: - GET /library

/// Scans the Quick and Archive library directories and returns all media files
/// as an array of VideoMetadata JSON.
///
/// Query params:
///   ?platform=YouTube   — filter by platform
///   ?archive=true|false — filter by archive mode
///   ?limit=50           — max results (default: 100)

func handleLibrary(
    request: Request,
    context: some RequestContext
) async throws -> Response {
    let queryItems = request.uri.queryParameters

    let platformFilter = queryItems.get("platform")
    let archiveFilter  = queryItems.get("archive").flatMap { Bool($0) }
    let limit          = queryItems.get("limit").flatMap { Int($0) } ?? 100

    let supportedExtensions: Set<String> = ["mp4", "mkv", "webm", "m4a", "mp3", "mov", "m4v"]
    var results: [VideoMetadata] = []

    func scan(_ root: URL, isArchive: Bool) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        while let url = enumerator.nextObject() as? URL {
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  let res = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  res.isRegularFile == true
            else { continue }

            let platform = LibraryPath.platformDisplayName(libraryRoot: root, fileURL: url)
            if let pf = platformFilter, let p = platform, p.lowercased() != pf.lowercased() { continue }
            if let af = archiveFilter, af != isArchive { continue }

            let (srtPaths, descPath, infoPath) = collectSidecars(near: url, isArchive: isArchive)
            let meta = VideoMetadata(
                url: "",
                title: url.deletingPathExtension().lastPathComponent,
                platform: platform,
                fileSize: Int64(res.fileSize ?? 0),
                outputPath: url.path,
                subtitlePaths: srtPaths,
                descriptionPath: descPath,
                infoJSONPath: infoPath,
                format: .bestVideo,
                isArchiveMode: isArchive,
                completedAt: res.contentModificationDate ?? .now
            )
            results.append(meta)
            if results.count >= limit { break }
        }
    }

    if let quick   = MediaStoragePaths.quickDownloadsRoot()  { scan(quick,   isArchive: false) }
    if let archive = MediaStoragePaths.archiveRoot(), results.count < limit { scan(archive, isArchive: true) }

    return try jsonResponse(results)
}

// MARK: - Sidecar helper (reused from PostProcessor)

private func collectSidecars(
    near fileURL: URL,
    isArchive: Bool
) -> (subtitlePaths: [String], descriptionPath: String?, infoJSONPath: String?) {
    guard isArchive,
          let contents = try? FileManager.default.contentsOfDirectory(
              at: fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil
          )
    else { return ([], nil, nil) }

    var srt: [String] = []
    var desc: String?
    var info: String?

    for item in contents {
        let ext = item.pathExtension.lowercased()
        if ext == "srt" || ext == "vtt"                           { srt.append(item.path) }
        else if item.lastPathComponent.hasSuffix(".description")  { desc = item.path }
        else if item.lastPathComponent.hasSuffix(".info.json")    { info = item.path }
    }
    return (srt.sorted(), desc, info)
}
