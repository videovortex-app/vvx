import ArgumentParser
import Foundation
import VideoVortexCore

// MARK: - SnapMode CLI conformance

/// `SnapMode` lives in VideoVortexCore without ArgumentParser dependency.
/// This extension adds the `ExpressibleByArgument` conformance needed for `@Option`.
extension SnapMode: ExpressibleByArgument {}

// MARK: - Command

/// Phase 3.5 Step 9: thin wrapper over GatherEngine.
struct GatherCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gather",
        abstract: "Search your archive and extract matching clips as a batch. (Pro feature)",
        discussion: """
        Searches vortex.db for the query and extracts every matching transcript segment
        as a frame-accurate MP4 clip into an organized output folder, accompanied by
        re-timed SRT subtitles, manifest.json, and clips.md.

        Clip window flags:
          --context-seconds N  Adds N seconds before/after each matched cue (default: 1.0,
                               start clamped at 0). Use 0 with --snap off for tight cuts.
          --snap off           Cue + context (default).
          --snap block         Exact cue bounds only; ignores --context-seconds.
          --snap chapter       Full chapter span containing the hit; ignores --context-seconds.
                               Falls back to block if chapter_index is missing (run vvx reindex).
          --pad N              Seconds of handle before/after logical in/out for NLE cross-dissolves
                               (default: 2.0). Applied by FFmpegRunner after snap/context resolution.

        Chapter-first gather (extract full creator-defined segments):
          vvx gather "AGI" --chapters-only
          vvx gather "AI safety" --chapters-only --limit 3
          vvx gather "robotics" --chapters-only --uploader "Lex Fridman" --pad 0
          vvx gather "energy" --chapters-only --after 2024-01-01 --limit 5
        Note: --snap chapter is implied with --chapters-only. --context-seconds is ignored.

        Examples:
          vvx gather "artificial general intelligence" --limit 10
          vvx gather "AI AND danger" --uploader "Lex Fridman" --context-seconds 2
          vvx gather "Tesla" --min-views 1000000 --min-likes 50000
          vvx gather "AGI" --snap chapter --limit 5
          vvx gather "Tesla" --min-views 1000000 --dry-run
          vvx gather "AGI" --limit 5 --fast -o ~/Desktop/agi-clips
          vvx gather "news" --max-total-duration 600
          vvx gather "neuralink" --pad 0      # tight cuts, no handles
          vvx gather "AGI safety" --chapters-only --limit 3
        """
    )

    // MARK: - Search flags

    @Argument(help: "Search query. Supports FTS5 syntax: AND, OR, NOT, phrase, prefix*.")
    var query: String

    @Option(name: .long, help: "Maximum number of clips to gather (default: 20).")
    var limit: Int = 20

    @Option(name: .long, help: "Filter by platform, e.g. YouTube, TikTok.")
    var platform: String?

    @Option(name: .long, help: "Only include videos uploaded on or after this date (YYYY-MM-DD).")
    var after: String?

    @Option(name: .long, help: "Filter by uploader or channel name (exact match).")
    var uploader: String?

    // MARK: - Engagement filters

    @Option(name: .long, help: "Only gather clips from videos with at least this many views.")
    var minViews: Int?

    @Option(name: .long, help: "Only gather clips from videos with at least this many likes.")
    var minLikes: Int?

    @Option(name: .long, help: "Only gather clips from videos with at least this many comments.")
    var minComments: Int?

    // MARK: - Boundary flags

    @Option(name: .long, help: "Adds N seconds before/after the matched cue (default: 1.0). Ignored when --snap block or --snap chapter.")
    var contextSeconds: Double = 1.0

    @Option(name: .long, help: "Snap mode: off (cue + context), block (exact cue), chapter (full chapter span). Default: off.")
    var snap: SnapMode?

    @Option(name: .long, help: "Hard cap on total resolved clip duration in seconds. Drops lower-relevance clips first.")
    var maxTotalDuration: Double?

    // MARK: - Pad flag

    @Option(name: .long, help: "Seconds of handle before and after each clip's logical in/out for NLE cross-dissolves; padded start is clamped at zero (default: 2.0).")
    var pad: Double = 2.0

    // MARK: - Extraction flags

    @Flag(name: .long, help: "Plan only: show what would be extracted without calling ffmpeg.")
    var dryRun: Bool = false

    @Option(name: [.customShort("o"), .long], help: "Output directory for extracted clips.")
    var output: String?

    @Flag(name: .long, help: "Fast mode: keyframe seek + stream copy (no re-encode). Instant but ±2-5s drift.")
    var fast: Bool = false

    @Flag(name: .long, help: "Re-encodes the clip using libx264 (CRF 18) to guarantee frame-accurate padding and high quality. Bypasses hardware acceleration. Mutually exclusive with --fast.")
    var exact: Bool = false

    // MARK: - Step 5 visual + convenience flags

    @Flag(name: .long, help: "Extract one JPEG still per clip at the logical clip start (L0), beside each MP4.")
    var thumbnails: Bool = false

    @Flag(name: [.customLong("open")], help: "After gather finishes, open the output folder in the system file manager (best-effort; skipped in dry-run).")
    var openOutput: Bool = false

    @Flag(name: [.customLong("embed-source")], help: "Embed source URL, title, and uploader into MP4 metadata during extraction (standard atoms; format limits apply).")
    var embedSource: Bool = false

    // MARK: - Chapter-first gather

    @Flag(name: .customLong("chapters-only"),
          help: """
          Search chapter titles instead of transcript text and extract each matching chapter \
          as a clip. Chapter boundaries are used directly — --snap chapter is implied and \
          --context-seconds is ignored. --pad is applied normally as NLE handles. \
          Mutually exclusive with --snap off and --snap block.
          """)
    var chaptersOnly: Bool = false

    // MARK: - Run

    mutating func run() async throws {
        // 1 — Mutual-exclusion (ArgumentParser-specific exit codes stay here)
        if fast && exact {
            print(VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "Cannot specify both --fast and --exact.",
                agentAction: "Use --fast for stream copy (quick, approximate handles) or --exact for re-encoded high-quality handles — not both."
            )).jsonString())
            throw ExitCode(VvxExitCode.forErrorCode(.parseError))
        }
        if chaptersOnly, let s = snap, s == .off || s == .block {
            print(VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "--snap off/block cannot be combined with --chapters-only. Chapter snap is implicit.",
                agentAction: "Remove --snap (or use --snap chapter, which is the default with --chapters-only)."
            )).jsonString())
            throw ExitCode(VvxExitCode.forErrorCode(.parseError))
        }

        // 2 — Entitlement gate (CLI owns this — MCP gate is in GatherTool)
        try await EntitlementChecker.requirePro(.gather)

        // 3 — Build config + call engine
        let config = GatherConfig(
            query:           query,
            limit:           limit,
            platform:        platform,
            after:           after,
            uploader:        uploader,
            minViews:        minViews,
            minLikes:        minLikes,
            minComments:     minComments,
            contextSeconds:  contextSeconds,
            snapMode:        snap ?? .off,
            maxTotalDuration: maxTotalDuration,
            pad:             pad,
            dryRun:          dryRun,
            fast:            fast,
            exact:           exact,
            thumbnails:      thumbnails,
            embedSource:     embedSource,
            chaptersOnly:    chaptersOnly,
            outputDir:       output
        )
        let result = await GatherEngine.run(config: config, progress: stderrLine)
        print(result)

        // 4 — Open output folder if --open requested (CLI-only feature)
        if openOutput, let summaryData = result.split(separator: "\n").last.flatMap({ $0.data(using: .utf8) }),
           let summary = try? JSONDecoder().decode(GatherSummaryLine.self, from: summaryData),
           summary.succeeded > 0 {
            revealOutputDirectory(summary.outputDir)
        }

        // 5 — Exit code: non-zero if any clip failed
        if result.contains("\"success\":false") {
            throw ExitCode(1)
        }
    }

    // MARK: - Open output folder (--open, gather only)

    private func revealOutputDirectory(_ path: String) {
        #if os(macOS)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        try? proc.run()
        #elseif os(Linux)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        proc.arguments = [path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        try? proc.run()
        #else
        Foundation.fputs("Note: --open is not supported on this platform.\n", stderr)
        #endif
    }
}

// MARK: - Free helpers

private func stderrLine(_ message: String) {
    Foundation.fputs(message + "\n", stderr)
}
