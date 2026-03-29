import ArgumentParser
import Foundation
import VideoVortexCore

struct SenseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sense",
        abstract: "Extract metadata and transcript from a video URL — no download.",
        discussion: """
        sense is the hero command. It runs yt-dlp with --skip-download to extract
        structured metadata and auto-generated subtitles in seconds, with zero media
        footprint. The result is a JSON object on stdout and an .srt file on disk.

        Agents should call `vvx sense <url>` and then read the file at `transcriptPath`
        to inject the full transcript into their context window.

        Examples:
          vvx sense "https://youtube.com/watch?v=..."
          vvx sense "https://x.com/user/status/..." --transcript
          vvx sense "https://tiktok.com/@user/video/123" --markdown
          vvx sense "https://youtube.com/watch?v=..." --browser safari
          vvx sense "https://youtube.com/watch?v=..." --no-sponsors
        """
    )

    @Argument(help: "The video URL to sense (YouTube, TikTok, X, Instagram, Vimeo, and 1000+ more).")
    var url: String

    @Flag(name: .long, help: "Print the raw SRT transcript to stdout instead of JSON metadata.")
    var transcript: Bool = false

    @Flag(name: .long, help: "Print a formatted Markdown document (title + metadata + transcript) to stdout.")
    var markdown: Bool = false

    @Option(name: .long, help: "Browser to borrow cookies from: safari, chrome, firefox, edge. Unlocks age-restricted and login-gated content.")
    var browser: String?

    @Flag(name: .long, help: "Strip SponsorBlock sponsor segments from the transcript. Requires ffmpeg.")
    var noSponsors: Bool = false

    @Option(name: .long, help: "Override transcript output directory (default: ~/.vvx/transcripts).")
    var transcriptDir: String?

    @Flag(name: .long, help: "Deprecated no-op. yt-dlp is no longer auto-updated by vvx.")
    var noAutoUpdate: Bool = false

    @Option(name: .long, help: "Maximum seconds to wait for yt-dlp before giving up. Default: 120.")
    var timeout: Double = 120

    @Flag(name: .long, help: "Request all English subtitle variants (uses en.*). Default is en,en-orig only; safer for YouTube rate limits.")
    var allSubs: Bool = false

    @Flag(name: .long, help: "Return metadata and token counts only — omits transcriptBlocks from the JSON output. estimatedTokens and chapter token counts are still populated for context-window planning. Useful for very long videos: peek first, then use --start/--end for specific sections.")
    var metadataOnly: Bool = false

    @Option(name: .long, help: "Start of transcript slice. Accepts HH:MM:SS, MM:SS, or decimal seconds. Defaults to 0 when omitted. The full transcript is always indexed; only stdout is sliced.")
    var start: String?

    @Option(name: .long, help: "End of transcript slice. Accepts HH:MM:SS, MM:SS, or decimal seconds. Open-ended when omitted.")
    var end: String?

    mutating func run() async throws {
        // Pre-flight: parse and validate --start / --end before touching the network.
        let parsedStart: Double
        let parsedEnd: Double

        if let s = start {
            guard let v = TimeParser.parseToSeconds(s) else {
                let err = VvxError(code: .parseError,
                                   message: "Cannot parse --start value '\(s)'.",
                                   url: url)
                printError(err)
                throw ExitCode(VvxExitCode.forErrorCode(err.code))
            }
            parsedStart = v
        } else {
            parsedStart = 0.0
        }

        if let e = end {
            guard let v = TimeParser.parseToSeconds(e) else {
                let err = VvxError(code: .parseError,
                                   message: "Cannot parse --end value '\(e)'.",
                                   url: url)
                printError(err)
                throw ExitCode(VvxExitCode.forErrorCode(err.code))
            }
            parsedEnd = v
        } else {
            parsedEnd = Double.infinity
        }

        if parsedStart >= parsedEnd {
            let err = VvxError(code: .invalidTimeRange,
                               message: "Invalid time range: --start (\(parsedStart)s) must be strictly less than --end (\(parsedEnd)s).",
                               url: url)
            printError(err)
            throw ExitCode(VvxExitCode.forErrorCode(err.code))
        }

        let isSlicing = start != nil || end != nil

        let config  = VvxConfig.load()
        let outDir  = transcriptDir.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        } ?? config.resolvedTranscriptDirectory()

        let resolver = EngineResolver.cliResolver
        guard let ytDlpURL = resolver.resolvedYtDlpURL() else {
            CLIOutputFormatter.engineNotFound()
            printError(VvxError(code: .engineNotFound,
                                message: "yt-dlp not found. Install with: brew install yt-dlp (macOS) or pip install yt-dlp.",
                                url: url))
            throw ExitCode(VvxExitCode.engineNotFound)
        }

        let senseConfig = SenseConfig(
            url: url,
            outputDirectory: outDir,
            ytDlpPath: ytDlpURL,
            browserCookies: browser,
            removeSponsorSegments: noSponsors,
            timeoutSeconds: timeout,
            allSubtitleLanguages: allSubs,
            requestHumanLikePacing: false
        )

        let senser    = VideoSenser()
        let startTime = Date()

        for await event in senser.sense(config: senseConfig) {
            switch event {
            case .preparing:
                CLIOutputFormatter.sensing(url: url)

            case .milestone(let milestone):
                CLIOutputFormatter.senseMilestone(milestone)

            case .completed(let result):
                // vortex.db has already received the FULL transcript at this point —
                // VideoSenser fires VortexIndexer inside its task before yielding
                // .completed. Slicing is applied only to stdout output below.
                let elapsed = Date().timeIntervalSince(startTime)
                CLIOutputFormatter.senseDone(elapsed: elapsed,
                                             transcriptPath: result.transcriptPath)

                // Apply slice to the stdout payload (DB is already written with full data).
                let outputResult = isSlicing
                    ? result.sliced(startSeconds: parsedStart, endSeconds: parsedEnd)
                    : result

                if transcript {
                    // --transcript outputs raw text; slicing applies via transcriptBlocks.
                    if !outputResult.transcriptBlocks.isEmpty {
                        print(outputResult.transcriptBlocks.map(\.text).joined(separator: " "))
                    } else if !isSlicing, let text = result.transcriptText() {
                        // Fallback to raw SRT only for unsliced mode (file may contain
                        // more than the slice, so skip the fallback when slicing is active).
                        print(SenseResult.stripSRTTimestamps(text))
                    } else {
                        fputs("No transcript available.\n", stderr)
                    }
                } else if markdown {
                    // markdownDocument() reads self.transcriptBlocks — naturally slice-local.
                    print(outputResult.markdownDocument())
                } else {
                    // Apply metadata-only stripping AFTER slicing so planning fields
                    // (estimatedTokens, chapter tokens) reflect the slice, not the full video.
                    let output = metadataOnly ? outputResult.withEmptyBlocks() : outputResult
                    print(output.jsonString())
                }

            case .retrying:
                CLIOutputFormatter.retrying()

            case .failed(let error):
                CLIOutputFormatter.senseFailed(error.message)
                CLIOutputFormatter.printErrorGuidance(for: error)
                printError(error)
                throw ExitCode(VvxExitCode.forErrorCode(error.code))

            @unknown default:
                break
            }
        }
    }
}

// MARK: - Error output

/// Writes the error JSON envelope to stdout so agents piping vvx don't need to merge streams.
private func printError(_ error: VvxError) {
    print(VvxErrorEnvelope(error: error).jsonString())
}

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
