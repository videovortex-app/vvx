import Foundation
import Hummingbird
import VideoVortexCore

// MARK: - POST /ingest request/response

struct IngestRequest: Decodable {
    let urls: [String]
    let format: String?
    let archive: Bool?

    var resolvedFormat: DownloadFormat {
        switch (format ?? "best").lowercased() {
        case "1080", "1080p":           return .video1080
        case "720", "720p":             return .video720
        case "broll", "b-roll":         return .bRollMuted
        case "mp3", "audio":            return .audioOnlyMP3
        case "reactionkit", "reaction": return .reactionKit
        default:                        return .bestVideo
        }
    }
}

struct IngestResponse: Encodable {
    let taskIds: [String]
    let status: String
    let message: String
}

// MARK: - Route handler

func handleIngest(
    request: Request,
    context: some RequestContext,
    taskStore: TaskStore,
    resolver: EngineResolver
) async throws -> Response {
    guard let body = try? await request.body.collect(upTo: 1024 * 16),
          let decoded = try? JSONDecoder().decode(IngestRequest.self, from: Data(body.readableBytesView))
    else {
        return jsonError(status: .badRequest, message: "Invalid JSON body. Expected: {\"urls\": [...], \"format\": \"best\", \"archive\": false}")
    }

    guard !decoded.urls.isEmpty else {
        return jsonError(status: .badRequest, message: "urls array must not be empty.")
    }

    guard let ytDlpURL = resolver.resolvedYtDlpURL() else {
        return jsonError(status: .serviceUnavailable, message: "yt-dlp not found. Install with: brew install yt-dlp (macOS) or pip install yt-dlp (all platforms).")
    }

    var taskIds: [UUID] = []

    for url in decoded.urls.prefix(20) {  // cap batch at 20
        let taskId = UUID()
        await taskStore.create(taskId: taskId, url: url)
        taskIds.append(taskId)

        let format    = decoded.resolvedFormat
        let isArchive = (decoded.archive ?? false) || format == .reactionKit
        let outDir: URL = isArchive
            ? (MediaStoragePaths.archiveRoot() ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/VideoVortex Archives"))
            : (MediaStoragePaths.quickDownloadsRoot() ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/VideoVortex"))

        let thumbCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vvx/thumbnails")
        let multiURL = decoded.urls.count > 1
        let config = DownloadJobConfig(
            url: url,
            format: format,
            isArchiveMode: isArchive,
            outputDirectory: outDir,
            ytDlpPath: ytDlpURL,
            ffmpegPath: resolver.resolvedFfmpegURL(),
            requestHumanLikePacing: multiURL
        )

        let capturedTaskId = taskId
        Task.detached {
            let downloader = VideoDownloader(thumbnailCacheDirectory: thumbCache)
            for await event in downloader.download(config: config) {
                switch event {
                case .preparing:
                    await taskStore.update(taskId: capturedTaskId) { $0.status = .downloading }
                case .downloading(let pct, let speed, let eta):
                    await taskStore.update(taskId: capturedTaskId) {
                        $0.progressPercent = pct
                        $0.speed = speed
                        $0.eta   = eta
                    }
                case .titleResolved(let title):
                    await taskStore.update(taskId: capturedTaskId) { $0.title = title }
                case .resolutionResolved(let res):
                    await taskStore.update(taskId: capturedTaskId) { $0.resolution = res }
                case .completed(let metadata):
                    await taskStore.update(taskId: capturedTaskId) {
                        $0.status      = .completed
                        $0.result      = metadata
                        $0.completedAt = .now
                    }
                case .retrying:
                    await taskStore.update(taskId: capturedTaskId) {
                        $0.speed = "updating engine..."
                    }
                case .failed(let error):
                    await taskStore.update(taskId: capturedTaskId) {
                        $0.status      = .failed
                        $0.error       = "\(error.message) (\(error.code.rawValue))"
                        $0.completedAt = .now
                    }
                default:
                    break
                }
            }
        }
    }

    let response = IngestResponse(
        taskIds: taskIds.map(\.uuidString),
        status: "queued",
        message: "\(taskIds.count) download(s) queued. Poll /status/{taskId} for progress."
    )
    return try jsonResponse(response)
}
