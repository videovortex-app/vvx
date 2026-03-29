import Foundation
import VideoVortexCore

/// MCP implementation of the `fetch` tool.
///
/// Downloads a video to the local archive and returns VideoMetadata JSON
/// with the absolute file paths of all generated files.
/// All errors are returned as VvxErrorEnvelope JSON with an agentAction field.
enum FetchTool {

    static func call(arguments: [String: Any]) async throws -> String {
        guard let url = arguments["url"] as? String, !url.isEmpty else {
            throw McpToolError.missingArgument("url")
        }

        let isArchive  = arguments["archive"]           as? Bool   ?? false
        let formatStr  = arguments["format"]            as? String ?? "best"
        let browserArg = arguments["cookiesFromBrowser"] as? String
        let noSponsors = arguments["noSponsors"]         as? Bool   ?? false
        let allSubs    = arguments["allSubs"]            as? Bool   ?? false
        _ = arguments["noAutoUpdate"] as? Bool ?? false // deprecated MCP flag; ignored

        let browser: String? = (browserArg == nil || browserArg == "none") ? nil : browserArg

        let resolver = EngineResolver.cliResolver
        guard let ytDlpURL = resolver.resolvedYtDlpURL() else {
            let err = VvxError(code: .engineNotFound,
                               message: "yt-dlp not found.",
                               url: url)
            return VvxErrorEnvelope(error: err).jsonString()
        }

        let downloadFormat   = parseFormat(formatStr)
        let effectiveArchive = isArchive || downloadFormat == .reactionKit

        let outDir: URL
        if effectiveArchive {
            guard let root = MediaStoragePaths.archiveRoot() else {
                let err = VvxError(code: .permissionDenied,
                                   message: "Could not resolve archive directory.",
                                   url: url)
                return VvxErrorEnvelope(error: err).jsonString()
            }
            outDir = root
        } else {
            guard let root = MediaStoragePaths.quickDownloadsRoot() else {
                let err = VvxError(code: .permissionDenied,
                                   message: "Could not resolve downloads directory.",
                                   url: url)
                return VvxErrorEnvelope(error: err).jsonString()
            }
            outDir = root
        }

        let thumbCacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vvx/thumbnails")

        let config = DownloadJobConfig(
            url: url,
            format: downloadFormat,
            isArchiveMode: effectiveArchive,
            outputDirectory: outDir,
            ytDlpPath: ytDlpURL,
            ffmpegPath: resolver.resolvedFfmpegURL(),
            browserCookies: browser,
            removeSponsorSegments: noSponsors,
            allSubtitleLanguages: allSubs
        )

        let downloader = VideoDownloader(thumbnailCacheDirectory: thumbCacheDir)
        var metadata: VideoMetadata?
        var fetchError: VvxError?

        for await event in downloader.download(config: config) {
            switch event {
            case .completed(let m):         metadata = m
            case .failed(let err):          fetchError = err
            case .preparing:                log("fetch: preparing \(url)")
            case .retrying:                 log("fetch: retrying after engine update")
            case .titleResolved(let t):     log("fetch: \(t)")
            case .outputPathResolved:       break
            case .downloading:              break
            case .resolutionResolved:       break
            @unknown default:               break
            }
        }

        if let error = fetchError {
            return VvxErrorEnvelope(error: error).jsonString()
        }

        guard let result = metadata else {
            let err = VvxError(code: .unknownError,
                               message: "Download completed without metadata.",
                               url: url)
            return VvxErrorEnvelope(error: err).jsonString()
        }

        return result.jsonString()
    }

    // MARK: - Format parsing (full CLI parity with FetchCommand)

    private static func parseFormat(_ string: String) -> DownloadFormat {
        switch string.lowercased() {
        case "1080", "1080p":               return .video1080
        case "720", "720p":                 return .video720
        case "broll", "b-roll":             return .bRollMuted
        case "audio", "mp3":               return .audioOnlyMP3
        case "reactionkit", "reaction-kit": return .reactionKit
        default:                            return .bestVideo
        }
    }
}
