import ArgumentParser
import Foundation
import VideoVortexCore
import Logging

// MARK: - Root (routing only)

/// Root command: **must not** define a positional `@Argument` alongside named subcommands —
/// ArgumentParser would consume `doctor`, `sense`, etc. as the URL. All `vvx <url>` behavior
/// lives in `ImplicitDefault`, registered as `defaultSubcommand`.
@main
struct Vvx: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vvx",
        abstract: "The clean video data pipe for LLM agents.",
        discussion: """
        vvx turns any video URL into structured JSON + transcript in seconds.
        Running `vvx <url>` with no flags defaults to `sense` — metadata and
        transcript extraction with zero media download.

        Batch mode: pipe URLs via stdin or use --batch:
          cat urls.txt | vvx          # sense all, NDJSON output
          vvx --batch urls.txt        # batch sense from file

        Install:  brew install videovortex-app/tap/vvx
        Docs:     https://videovortex.app/cli
        """,
        subcommands: [
            ImplicitDefault.self,
            SenseCommand.self,
            FetchCommand.self,
            DlCommand.self,
            SyncCommand.self,
            SearchCommand.self,
            GatherCommand.self,
            ClipCommand.self,
            LibraryCommand.self,
            ReindexCommand.self,
            IngestCommand.self,
            SqlCommand.self,
            EngineCommand.self,
            DoctorCommand.self,
            DocsCommand.self,
        ],
        defaultSubcommand: ImplicitDefault.self
    )

    /// Parent `run` is not used when subcommands / defaultSubcommand handle execution.
    mutating func run() async throws {
        VvxLogging.bootstrap()
    }
}

// MARK: - Implicit default (`vvx <url>`, batch, stdin)

struct ImplicitDefault: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_default",
        shouldDisplay: false
    )

    @Argument(help: "Video URL. Defaults to sense (metadata + transcript, no download).")
    var url: String?

    @Flag(name: .long, help: "Download the video file.")
    var download: Bool = false

    @Flag(name: .long, help: "Full archive: MP4 + SRT + .info.json + thumbnail in a per-video folder.")
    var archive: Bool = false

    @Flag(name: .long, help: "Print the raw SRT transcript to stdout instead of JSON.")
    var transcript: Bool = false

    @Flag(name: .long, help: "Print a formatted Markdown document (title + metadata + transcript) to stdout.")
    var markdown: Bool = false

    @Option(name: .long, help: "Browser for cookies: safari, chrome, arc, firefox.")
    var browser: String?

    @Flag(name: .long, help: "Strip SponsorBlock sponsor segments from transcript and media.")
    var noSponsors: Bool = false

    @Flag(name: .long, help: "Deprecated no-op. yt-dlp is no longer auto-updated by vvx.")
    var noAutoUpdate: Bool = false

    @Option(name: .long, help: "Path to a text file with one URL per line. Runs sense on all URLs and outputs NDJSON.")
    var batch: String? = nil

    @Flag(name: .long, help: "Request all English subtitle variants (en.*) for sense/fetch. Default is en,en-orig; safer against YouTube 429s.")
    var allSubs: Bool = false

    mutating func run() async throws {
        VvxLogging.bootstrap()

        if let batchPath = batch {
            try await runBatchSense(
                urls: StdinReader.resolveURLs(explicit: [], batchFile: batchPath)
            )
            return
        }

        if url == nil && isatty(STDIN_FILENO) == 0 {
            let stdinURLs = StdinReader.resolveURLs(explicit: [], batchFile: nil)
            if !stdinURLs.isEmpty {
                try await runBatchSense(urls: stdinURLs)
                return
            }
        }

        guard let url else {
            throw CleanExit.helpRequest()
        }

        if download || archive {
            var cmd            = FetchCommand()
            cmd.urls           = [url]
            cmd.archive        = archive
            cmd.json           = !transcript && !markdown
            cmd.browser        = browser
            cmd.noSponsors     = noSponsors
            cmd.noAutoUpdate   = noAutoUpdate
            cmd.allSubs        = allSubs
            try await cmd.run()
        } else {
            var cmd           = SenseCommand()
            cmd.url           = url
            cmd.transcript    = transcript
            cmd.markdown      = markdown
            cmd.browser       = browser
            cmd.noSponsors    = noSponsors
            cmd.noAutoUpdate  = noAutoUpdate
            cmd.allSubs       = allSubs
            try await cmd.run()
        }
    }

    private func runBatchSense(urls: [String]) async throws {
        guard !urls.isEmpty else {
            fputs("vvx: no URLs to process.\n", stderr)
            return
        }

        let resolver = EngineResolver.cliResolver
        guard let ytDlpURL = resolver.resolvedYtDlpURL() else {
            CLIOutputFormatter.engineNotFound()
            throw ExitCode(VvxExitCode.engineNotFound)
        }

        let config = VvxConfig.load()
        let outDir = config.resolvedTranscriptDirectory()

        NDJSONStreamer.batchStart(count: urls.count)

        let succeeded = ActorCounter()
        let failed    = ActorCounter()

        let pacingBatch = urls.count > 1

        await withTaskGroup(of: Void.self) { group in
            var active = 0
            var index  = 0

            for url in urls {
                if active >= 3 {
                    await group.next()
                    active -= 1
                }

                let currentIndex = index + 1
                let total        = urls.count
                let senseConfig  = SenseConfig(
                    url: url,
                    outputDirectory: outDir,
                    ytDlpPath: ytDlpURL,
                    browserCookies: browser,
                    removeSponsorSegments: noSponsors,
                    allSubtitleLanguages: allSubs,
                    requestHumanLikePacing: pacingBatch
                )
                let senser = VideoSenser()

                group.addTask {
                    for await event in senser.sense(config: senseConfig) {
                        switch event {
                        case .completed(let result):
                            NDJSONStreamer.progressLine(
                                index: currentIndex, total: total,
                                title: result.title, success: true
                            )
                            NDJSONStreamer.writeSenseResult(result)
                            await succeeded.increment()
                        case .failed(let error):
                            NDJSONStreamer.progressLine(
                                index: currentIndex, total: total,
                                title: nil, success: false
                            )
                            NDJSONStreamer.writeError(error)
                            await failed.increment()
                        default:
                            break
                        }
                    }
                }

                active += 1
                index  += 1
            }

            for await _ in group {}
        }

        let s = await succeeded.value
        let f = await failed.value
        NDJSONStreamer.batchDone(succeeded: s, failed: f)
    }
}

// MARK: - Thread-safe counter

private actor ActorCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

// MARK: - Convenience

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
