import ArgumentParser
import Foundation
import VideoVortexCore

struct DlCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dl",
        abstract: "Download a video straight to your Downloads folder.",
        discussion: """
        Zero-friction human download: no archive sidecars, no vortex.db, no JSON.
        Bare domains (without https://) are accepted automatically.

        Optional quality (one at a time): --1080, --720, --audio (MP3).
        """
    )

    @Argument(help: "Video URL (https:// optional).")
    var url: String

    @Flag(name: .customLong("1080"), help: "Cap resolution at 1080p.")
    var is1080: Bool = false

    @Flag(name: .customLong("720"), help: "Cap resolution at 720p.")
    var is720: Bool = false

    @Flag(name: .customLong("audio"), help: "Audio only (MP3).")
    var isAudio: Bool = false

    func validate() throws {
        let selected = [is1080, is720, isAudio].filter { $0 }.count
        if selected > 1 {
            throw ValidationError("Use at most one of --1080, --720, or --audio.")
        }
    }

    mutating func run() async throws {
        let resolver = EngineResolver.cliResolver
        guard let ytDlpURL = resolver.resolvedYtDlpURL() else {
            CLIOutputFormatter.engineNotFound()
            throw ExitCode(VvxExitCode.engineNotFound)
        }

        let sanitizedURL = Self.normalizedURLString(url)
        let format = Self.resolvedFormat(is1080: is1080, is720: is720, isAudio: isAudio)
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let thumbCacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vvx/thumbnails")

        let config = DownloadJobConfig(
            url: sanitizedURL,
            format: format,
            isArchiveMode: false,
            outputDirectory: downloadsDir,
            ytDlpPath: ytDlpURL,
            ffmpegPath: resolver.resolvedFfmpegURL(),
            browserCookies: nil,
            removeSponsorSegments: false,
            allSubtitleLanguages: false,
            requestHumanLikePacing: false,
            indexInDatabase: false,
            useFlatOutputTemplate: true
        )

        let downloader = VideoDownloader(thumbnailCacheDirectory: thumbCacheDir)

        for await event in downloader.download(config: config) {
            switch event {
            case .preparing:
                fputs("\rPreparing...", stderr)
            case .downloading(let pct, let speed, let eta):
                let line = String(format: "\rDownloading... %.1f%% (%@) ETA: %@", pct * 100, speed, eta)
                fputs(line, stderr)
            case .retrying:
                fputs("\nEngine refreshed — retrying download...\n", stderr)
            case .completed(let metadata):
                let display = MediaStoragePaths.tildePath(for: URL(fileURLWithPath: metadata.outputPath))
                fputs("\n✓ Saved to \(display)\n", stderr)
            case .failed(let error):
                fputs("\n✗ \(error.message)\n", stderr)
                throw ExitCode(VvxExitCode.forErrorCode(error.code))
            case .titleResolved, .resolutionResolved, .outputPathResolved:
                break
            @unknown default:
                break
            }
        }
    }

    /// Prepends `https://` when no `http(s)://` scheme is present so bare hostnames work.
    private static func normalizedURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return trimmed }
        return "https://\(trimmed)"
    }

    private static func resolvedFormat(is1080: Bool, is720: Bool, isAudio: Bool) -> DownloadFormat {
        if isAudio { return .audioOnlyMP3 }
        if is720 { return .video720 }
        if is1080 { return .video1080 }
        return .bestVideo
    }
}

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
