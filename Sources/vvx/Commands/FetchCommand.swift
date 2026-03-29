import ArgumentParser
import Foundation
import VideoVortexCore

struct FetchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Download video URL(s) and output structured metadata.",
        discussion: """
        Downloads videos and saves them to the VideoVortex library folder.
        Accepts a single URL, multiple URLs, a batch file (--batch), or URLs
        piped via stdin. In batch mode, outputs NDJSON — one JSON object per
        completed URL streamed to stdout as each finishes.

        Examples:
          vvx fetch "https://youtube.com/watch?v=..."
          vvx fetch "https://youtube.com/..." --archive
          vvx fetch "https://youtube.com/..." --format broll
          vvx fetch url1 url2 url3                          # multi-URL
          vvx fetch --batch urls.txt --archive              # batch file
          cat urls.txt | vvx fetch                          # stdin pipe
          vvx fetch "https://youtube.com/..." --browser safari  # age-restricted
        """
    )

    @Argument(help: "Video URL(s) to download. Omit to read from stdin or --batch file.")
    var urls: [String] = []

    @Option(name: .long, help: "Path to a text file with one URL per line.")
    var batch: String? = nil

    @Option(name: .long, help: "Format: best (default), 1080p, 720p, broll, mp3, reactionkit.")
    var format: String = "best"

    @Flag(name: .long, help: "Archive mode: saves .srt, .info.json, and .description sidecars.")
    var archive: Bool = false

    @Flag(name: .long, help: "Print VideoMetadata JSON to stdout. Progress goes to stderr.")
    var json: Bool = false

    @Option(name: .long, help: "Output directory. Default: ~/Downloads/VideoVortex (quick) or ~/Movies/VideoVortex Archives (archive).")
    var outputDir: String?

    @Option(name: .long, help: "Browser to borrow cookies from: safari, chrome, arc, firefox. Unlocks age-restricted and login-gated content.")
    var browser: String?

    @Flag(name: .long, help: "Strip SponsorBlock sponsor segments from the media and transcript. Requires ffmpeg.")
    var noSponsors: Bool = false

    @Flag(name: .long, help: "Deprecated no-op. yt-dlp is no longer auto-updated by vvx.")
    var noAutoUpdate: Bool = false

    @Flag(name: .long, help: "Request all English subtitle variants (uses en.*). Higher YouTube traffic; default is en,en-orig only.")
    var allSubs: Bool = false

    // MARK: - Entry point

    mutating func run() async throws {
        let resolver = EngineResolver.cliResolver

        guard let ytDlpURL = resolver.resolvedYtDlpURL() else {
            CLIOutputFormatter.engineNotFound()
            throw ExitCode(VvxExitCode.engineNotFound)
        }

        let resolvedURLs = StdinReader.resolveURLs(explicit: urls, batchFile: batch)

        guard !resolvedURLs.isEmpty else {
            fputs("vvx fetch: no URLs provided. Pass a URL, use --batch, or pipe URLs via stdin.\n", stderr)
            throw ExitCode.failure
        }

        if resolvedURLs.count == 1 {
            try await runSingle(url: resolvedURLs[0], resolver: resolver, ytDlpURL: ytDlpURL)
        } else {
            try await runBatch(urls: resolvedURLs, resolver: resolver, ytDlpURL: ytDlpURL)
        }
    }

    // MARK: - Single URL

    private func runSingle(url: String, resolver: EngineResolver, ytDlpURL: URL) async throws {
        let downloadFormat = parseFormat(format)
        let isArchive      = archive || downloadFormat == .reactionKit
        let outDir         = try resolveOutputDir(isArchive: isArchive)

        let thumbCacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vvx/thumbnails")

        let config = DownloadJobConfig(
            url: url,
            format: downloadFormat,
            isArchiveMode: isArchive,
            outputDirectory: outDir,
            ytDlpPath: ytDlpURL,
            ffmpegPath: resolver.resolvedFfmpegURL(),
            browserCookies: browser,
            removeSponsorSegments: noSponsors,
            allSubtitleLanguages: allSubs,
            requestHumanLikePacing: false
        )

        let downloader = VideoDownloader(thumbnailCacheDirectory: thumbCacheDir)
        var lastTitle: String?

        try await runDownloadLoop(
            downloader: downloader,
            config: config,
            lastTitle: &lastTitle,
            json: json
        )
    }

    private func runDownloadLoop(
        downloader: VideoDownloader,
        config: DownloadJobConfig,
        lastTitle: inout String?,
        json: Bool
    ) async throws {
        for await event in downloader.download(config: config) {
            switch event {
            case .preparing:
                CLIOutputFormatter.preparing()
            case .downloading(let pct, let speed, let eta):
                CLIOutputFormatter.progress(percent: pct, speed: speed, eta: eta)
            case .titleResolved(let title):
                if title != lastTitle {
                    lastTitle = title
                    CLIOutputFormatter.titleResolved(title)
                }
            case .resolutionResolved(let res):
                CLIOutputFormatter.resolutionResolved(res)
            case .outputPathResolved:
                break
            case .retrying:
                CLIOutputFormatter.retrying()
            case .completed(let metadata):
                if json {
                    CLIOutputFormatter.printJSON(metadata)
                } else {
                    CLIOutputFormatter.printSummary(metadata)
                }
            case .failed(let error):
                CLIOutputFormatter.failed(error.message)
                CLIOutputFormatter.printErrorGuidance(for: error)
                print(VvxErrorEnvelope(error: error).jsonString())
                throw ExitCode(VvxExitCode.forErrorCode(error.code))
            @unknown default:
                break
            }
        }
    }

    // MARK: - Batch (multi-URL or stdin)

    private func runBatch(urls: [String], resolver: EngineResolver, ytDlpURL: URL) async throws {
        let downloadFormat = parseFormat(format)
        let isArchive      = archive || downloadFormat == .reactionKit
        let outDir         = try resolveOutputDir(isArchive: isArchive)
        let thumbCacheDir  = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vvx/thumbnails")

        NDJSONStreamer.batchStart(count: urls.count)

        let succeeded = ActorCounter()
        let failed    = ActorCounter()

        await withTaskGroup(of: Void.self) { group in
            var active = 0
            var index  = 0

            for url in urls {
                // Enforce max 3 concurrent downloads to avoid platform rate limits
                if active >= 3 {
                    await group.next()
                    active -= 1
                }

                let currentIndex = index + 1
                let total = urls.count
                let config = DownloadJobConfig(
                    url: url,
                    format: downloadFormat,
                    isArchiveMode: isArchive,
                    outputDirectory: outDir,
                    ytDlpPath: ytDlpURL,
                    ffmpegPath: resolver.resolvedFfmpegURL(),
                    browserCookies: browser,
                    removeSponsorSegments: noSponsors,
                    allSubtitleLanguages: allSubs,
                    requestHumanLikePacing: true
                )
                let downloader = VideoDownloader(thumbnailCacheDirectory: thumbCacheDir)

                group.addTask {
                    var lastTitle: String?
                    var didSucceed = false
                    var lastProgressBucket: Int?

                    for await event in downloader.download(config: config) {
                        switch event {
                        case .titleResolved(let t):
                            lastTitle = t
                            fputs("  [\(currentIndex)/\(total)] \(t)\n", stderr)
                        case .completed(let metadata):
                            NDJSONStreamer.progressLine(
                                index: currentIndex, total: total,
                                title: metadata.title, success: true
                            )
                            CLIOutputFormatter.printJSON(metadata)
                            didSucceed = true
                        case .failed(let err):
                            NDJSONStreamer.progressLine(
                                index: currentIndex, total: total,
                                title: lastTitle, success: false
                            )
                            NDJSONStreamer.writeError(err)
                        case .preparing:
                            fputs("  [\(currentIndex)/\(total)] Preparing…\n", stderr)
                        case .downloading(let pct, _, _):
                            // `pct` is 0.0–1.0. Print only when crossing 0/25/50/75/100% buckets
                            // to avoid log spam (yt-dlp can emit many 0.0% updates early).
                            let pct100 = max(0, min(100, Int((pct * 100.0).rounded())))
                            let bucket = (pct100 / 25) * 25
                            if lastProgressBucket != bucket {
                                lastProgressBucket = bucket
                                fputs("  [\(currentIndex)/\(total)] \(bucket)%\n", stderr)
                            }
                        case .retrying:
                            fputs("  [\(currentIndex)/\(total)] Retrying…\n", stderr)
                        case .resolutionResolved, .outputPathResolved:
                            break
                        @unknown default:
                            break
                        }
                    }

                    if didSucceed {
                        await succeeded.increment()
                    } else {
                        await failed.increment()
                    }
                }

                active += 1
                index  += 1
            }

            // Drain remaining tasks
            for await _ in group {}
        }

        let s = await succeeded.value
        let f = await failed.value
        NDJSONStreamer.batchDone(succeeded: s, failed: f)
    }

    // MARK: - Helpers

    private func resolveOutputDir(isArchive: Bool) throws -> URL {
        if let custom = outputDir {
            return URL(fileURLWithPath: custom).standardizedFileURL
        }
        if isArchive {
            guard let root = MediaStoragePaths.archiveRoot() else {
                fputs("✗ Could not resolve archive directory.\n", stderr)
                throw ExitCode.failure
            }
            return root
        }
        guard let root = MediaStoragePaths.quickDownloadsRoot() else {
            fputs("✗ Could not resolve downloads directory.\n", stderr)
            throw ExitCode.failure
        }
        return root
    }

    private func parseFormat(_ string: String) -> DownloadFormat {
        switch string.lowercased() {
        case "best", "bestvideo":       return .bestVideo
        case "1080", "1080p":           return .video1080
        case "720", "720p":             return .video720
        case "broll", "b-roll":         return .bRollMuted
        case "mp3", "audio":            return .audioOnlyMP3
        case "reactionkit", "reaction": return .reactionKit
        default:                        return .bestVideo
        }
    }
}

// MARK: - Thread-safe counter for batch reporting

private actor ActorCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

// MARK: - Convenience

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
