import ArgumentParser
import Foundation
import VideoVortexCore

// MARK: - ArgumentParser conformance for NleExportFormat
// Note: SnapMode: ExpressibleByArgument is already declared in GatherCommand.swift.

extension NleExportFormat: ExpressibleByArgument {}

// MARK: - SearchCommand

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Full-text search across all indexed transcripts.",
        discussion: """
        Searches the local vortex.db FTS5 index for the given query and returns
        ranked results with timestamps, snippets, and 2-block context windows.

        Supports FTS5 query syntax: boolean operators (AND, OR, NOT), phrase search
        ("exact phrase"), and prefix search (intell*). Porter stemming is active by
        default — "run" matches "running", "AGI" matches "AGIs".

        Default output is JSON on stdout.  Use --rag for agent-optimized Markdown
        with per-hit attribution and ready-to-run vvx clip commands.

        NLE export (Pro):
          vvx search "neuralink" --export-nle fcpx     --export-nle-out ~/Desktop/cuts.fcpxml
          vvx search "neuralink" --export-nle premiere --export-nle-out ~/Desktop/cuts.xml
          vvx search "neuralink" --export-nle resolve  --export-nle-out ~/Desktop/cuts.edl
          Imports into Final Cut Pro, Premiere Pro, or DaVinci Resolve as a ready-to-cut
          project referencing archive files in-place — zero re-encode.

        Structural search (no query required):
          vvx search --uploader "Lex Fridman" --longest-monologue
          vvx search --platform YouTube --high-density --limit 10
          vvx search --after 2025-01-01 --longest-monologue --monologue-gap 3.0
          vvx search --uploader "Joe Rogan" --high-density --density-window 30 --limit 5

        Examples:
          vvx search "artificial general intelligence"
          vvx search "AGI" --limit 20
          vvx search "AI AND danger"
          vvx search "mars colonization" --platform YouTube
          vvx search "specific quote" --after 2025-01-01
          vvx search "interview" --uploader "Lex Fridman"
          vvx search "AGI" --rag
          vvx search "neuralink" --export-nle fcpx --export-nle-out ~/Desktop/cuts.fcpxml
          vvx search "AGI" --export-nle fcpx --export-nle-out ~/Desktop/agi.fcpxml --dry-run
          vvx search --uploader "Lex Fridman" --longest-monologue --limit 5
          vvx search --platform YouTube --high-density --density-window 30 --limit 10
        """
    )

    // MARK: - Base search flags

    @Argument(help: "FTS5 search query. Required for keyword search and NLE export. Not required when using --longest-monologue or --high-density.")
    var query: String?

    @Option(name: .long, help: "Maximum number of results to return (default: 50).")
    var limit: Int = 50

    @Option(name: .long, help: "Filter by platform, e.g. YouTube, TikTok, Twitter.")
    var platform: String?

    @Option(name: .long, help: "Only include results from videos uploaded on or after this date (YYYY-MM-DD).")
    var after: String?

    @Option(name: .long, help: "Filter by uploader or channel name (exact match).")
    var uploader: String?

    // MARK: - JSON/RAG output flags

    @Flag(name: .long, help: "Output agent-optimized Markdown with per-hit attribution and vvx clip commands. Recommended for RAG workflows.")
    var rag: Bool = false

    @Option(name: .long, help: "Maximum estimated tokens for --rag output. Truncates hits before exceeding this budget. Requires --rag.")
    var maxTokens: Int?

    // MARK: - NLE export flags

    @Option(name: .customLong("export-nle"),
            help: "NLE export format. Supported: fcpx (Final Cut Pro), premiere (Premiere Pro XML), resolve (DaVinci Resolve EDL). Requires --export-nle-out.")
    var exportNle: NleExportFormat?

    @Option(name: .customLong("export-nle-out"),
            help: "Output path for the NLE export file (e.g. ~/Desktop/cuts.fcpxml, ~/Desktop/cuts.xml, ~/Desktop/cuts.edl). Required with --export-nle.")
    var exportNleOut: String?

    @Option(name: .long,
            help: "Seconds of handle before/after each cue; written as source in/out timecodes in the exported NLE file (default: 2.0).")
    var pad: Double = 2.0

    @Option(name: .customLong("context-seconds"),
            help: "Seconds of context around each matched cue before snap resolution (default: 1.0). Only applies to NLE export.")
    var contextSeconds: Double = 1.0

    @Option(name: .long,
            help: "Clip window snap mode: off (cue + context), block (exact cue), chapter (full chapter span). Default: off.")
    var snap: SnapMode = .off

    @Option(name: .customLong("frame-rate"),
            help: "NLE display timebase: FCPXML sequence ruler, Premiere sequence, and EDL SMPTE timecode frame rate (default: 29.97). Does not affect clip trim accuracy.")
    var frameRate: Double = 29.97

    @Flag(name: .long,
          help: "Print planned clip list without writing the NLE export file.")
    var dryRun: Bool = false

    // MARK: - Structural search flags (Phase 1 — Step 8)

    @Flag(name: .customLong("longest-monologue"),
          help: "Find the longest contiguous speech span per video. Sorted by duration descending. No query required. Compatible with --uploader, --platform, --after, --limit, --monologue-gap.")
    var longestMonologue: Bool = false

    @Flag(name: .customLong("high-density"),
          help: "Find the highest words-per-second window per video. Sorted by density descending. No query required. Compatible with --uploader, --platform, --after, --limit, --density-window.")
    var highDensity: Bool = false

    @Option(name: .customLong("monologue-gap"),
            help: "Maximum gap in seconds between consecutive transcript blocks still considered part of the same monologue span. Only applies to --longest-monologue. Default: 1.5. Must be >= 0.")
    var monologueGap: Double = 1.5

    @Option(name: .customLong("density-window"),
            help: "Sliding window width in seconds for --high-density scoring. Use 30 for tight highlight-reel clips. Default: 60.0. Must be > 0.")
    var densityWindow: Double = 60.0

    // MARK: - Run

    mutating func run() async throws {
        let isStructural = longestMonologue || highDensity

        // --- Mutual-exclusion validation (runs before any DB open) ----------

        guard isStructural || query != nil else {
            emitError(code: .parseError,
                      message: "A search query is required when neither --longest-monologue nor --high-density is specified.",
                      agentAction: "Provide a search query string, or use --longest-monologue / --high-density for structural analysis.")
            throw ExitCode(VvxExitCode.userError)
        }
        if isStructural, query != nil {
            emitError(code: .parseError,
                      message: "--longest-monologue / --high-density cannot be combined with a query string.",
                      agentAction: "Remove the query to run structural analysis, or remove the structural flag to run keyword search.")
            throw ExitCode(VvxExitCode.userError)
        }
        if longestMonologue && highDensity {
            emitError(code: .parseError,
                      message: "--longest-monologue and --high-density cannot be used together.",
                      agentAction: "Use --longest-monologue OR --high-density — not both in the same command.")
            throw ExitCode(VvxExitCode.userError)
        }
        if isStructural, exportNle != nil {
            emitError(code: .parseError,
                      message: "--export-nle cannot be combined with --longest-monologue or --high-density.",
                      agentAction: "Use a keyword query with --export-nle, or use the structural flag alone.")
            throw ExitCode(VvxExitCode.userError)
        }
        if monologueGap < 0 {
            emitError(code: .parseError,
                      message: "--monologue-gap must be >= 0.",
                      agentAction: "--monologue-gap must be a non-negative number of seconds (e.g. --monologue-gap 1.5).")
            throw ExitCode(VvxExitCode.userError)
        }
        if densityWindow <= 0 {
            emitError(code: .parseError,
                      message: "--density-window must be > 0.",
                      agentAction: "--density-window must be a positive number of seconds (e.g. --density-window 60.0).")
            throw ExitCode(VvxExitCode.userError)
        }

        // --- Branch ---------------------------------------------------------

        if isStructural {
            try await runStructuralSearch()
            return
        }

        if exportNle != nil || exportNleOut != nil {
            try await runNLEExport()
            return
        }

        // --- Standard JSON / RAG branch -------------------------------------
        guard maxTokens == nil || rag else {
            printNDJSON(SearchErrorEnvelope(
                query: query ?? "",
                message: "--max-tokens requires --rag."
            ))
            throw ExitCode(VvxExitCode.userError)
        }

        fputs("Searching vortex.db…\n", stderr)

        let db: VortexDB
        do {
            db = try VortexDB.open()
        } catch {
            let envelope = SearchErrorEnvelope(
                query:   query ?? "",
                message: "Could not open vortex.db: \(error.localizedDescription)"
            )
            printNDJSON(envelope)
            throw ExitCode(1)
        }

        let output: SearchOutput
        do {
            output = try await SRTSearcher.search(
                query:     query ?? "",
                db:        db,
                platform:  platform,
                afterDate: after,
                uploader:  uploader,
                limit:     limit
            )
        } catch {
            let envelope = SearchErrorEnvelope(
                query:   query ?? "",
                message: "Search failed: \(error.localizedDescription)"
            )
            printNDJSON(envelope)
            throw ExitCode(1)
        }

        fputs("Found \(output.totalMatches) result(s).\n", stderr)

        if rag {
            let markdown = SRTSearcher.ragMarkdown(
                query:              query ?? "",
                results:            output.results,
                totalBeforeBudget:  output.totalMatches,
                maxTokens:          maxTokens,
                versionString:      vvxDocsVersion
            )
            print(markdown)
        } else {
            print(output.jsonString())
        }
    }

    // MARK: - Structural search

    private mutating func runStructuralSearch() async throws {
        let modeName = longestMonologue ? "longest_monologue" : "high_density"

        // Open DB
        let db: VortexDB
        do {
            db = try VortexDB.open()
        } catch {
            emitError(code: .indexCorrupt,
                      message: "Could not open vortex.db: \(error.localizedDescription)")
            throw ExitCode(VvxExitCode.forErrorCode(.indexCorrupt))
        }

        // Load lightweight video list
        let summaries: [VideoSummary]
        do {
            summaries = try await db.videoSummaries(
                platform:  platform,
                uploader:  uploader,
                afterDate: after
            )
        } catch {
            emitError(code: .indexCorrupt,
                      message: "Could not query videos: \(error.localizedDescription)")
            throw ExitCode(VvxExitCode.forErrorCode(.indexCorrupt))
        }

        fputs("Scanning \(summaries.count) video(s) for structural analysis…\n", stderr)

        // Fan-out: analyse each video's blocks
        struct ScoredResult {
            let summary:  VideoSummary
            let monologue: MonologueSpan?
            let density:   DensitySpan?
            var score: Double {
                monologue.map(\.durationSeconds) ?? density.map(\.wordsPerSecond) ?? 0
            }
        }

        var results: [ScoredResult] = []

        for summary in summaries {
            let blocks: [StoredBlock]
            do {
                blocks = try await db.blocksForVideo(videoId: summary.id)
            } catch {
                continue
            }
            guard !blocks.isEmpty else { continue }

            if longestMonologue {
                if let span = StructuralAnalyzer.longestMonologue(
                    blocks: blocks,
                    maxGapSeconds: monologueGap
                ) {
                    results.append(ScoredResult(summary: summary, monologue: span, density: nil))
                }
            } else {
                if let span = StructuralAnalyzer.highDensityWindow(
                    blocks: blocks,
                    windowSeconds: densityWindow
                ) {
                    results.append(ScoredResult(summary: summary, monologue: nil, density: span))
                }
            }
        }

        // Sort descending by score (duration or words-per-second)
        results.sort { $0.score > $1.score }

        // Apply limit
        let topResults = Array(results.prefix(limit))

        // Emit per-result NDJSON
        for (i, r) in topResults.enumerated() {
            let rank = i + 1
            if let span = r.monologue {
                let startS = span.startSeconds
                let endS   = span.endSeconds
                let repro  = reproduceCommand(videoPath: r.summary.videoPath,
                                              start: startS, end: endS)
                printNDJSON(MonologueResultLine(
                    rank:              rank,
                    videoTitle:        r.summary.title,
                    uploader:          r.summary.uploader,
                    platform:          r.summary.platform,
                    uploadDate:        r.summary.uploadDate,
                    videoPath:         r.summary.videoPath,
                    startSeconds:      startS,
                    endSeconds:        endS,
                    durationSeconds:   span.durationSeconds,
                    blockCount:        span.blockCount,
                    structuralScore:   span.durationSeconds,
                    transcriptExcerpt: span.transcriptExcerpt,
                    reproduceCommand:  repro
                ))
            } else if let span = r.density {
                let startS = span.startSeconds
                let endS   = span.endSeconds
                let repro  = reproduceCommand(videoPath: r.summary.videoPath,
                                              start: startS, end: endS)
                printNDJSON(DensityResultLine(
                    rank:              rank,
                    videoTitle:        r.summary.title,
                    uploader:          r.summary.uploader,
                    platform:          r.summary.platform,
                    uploadDate:        r.summary.uploadDate,
                    videoPath:         r.summary.videoPath,
                    startSeconds:      startS,
                    endSeconds:        endS,
                    windowSeconds:     densityWindow,
                    wordCount:         span.wordCount,
                    wordsPerSecond:    span.wordsPerSecond,
                    structuralScore:   span.wordsPerSecond,
                    transcriptExcerpt: span.transcriptExcerpt,
                    reproduceCommand:  repro
                ))
            }
        }

        // Emit summary NDJSON
        printNDJSON(StructuralSummaryLine(
            mode:          modeName,
            scannedVideos: summaries.count,
            resultCount:   topResults.count,
            limit:         limit,
            uploader:      uploader,
            platform:      platform,
            afterDate:     after
        ))

        fputs("Found \(topResults.count) result(s) from \(summaries.count) video(s).\n", stderr)
    }

    // MARK: - NLE export run

    private mutating func runNLEExport() async throws {

        // 1 — Flag validation
        guard let format = exportNle else {
            emitError(code: .parseError,
                      message: "--export-nle-out requires --export-nle <format>.",
                      agentAction: "Add --export-nle with a format: fcpx, premiere, or resolve.")
            throw ExitCode(VvxExitCode.userError)
        }
        guard let outPath = exportNleOut else {
            emitError(code: .parseError,
                      message: "--export-nle requires --export-nle-out <path>.",
                      agentAction: "Add --export-nle-out with the output path (e.g. ~/Desktop/cuts.fcpxml, ~/Desktop/cuts.xml, ~/Desktop/cuts.edl).")
            throw ExitCode(VvxExitCode.userError)
        }
        if rag {
            emitError(code: .parseError,
                      message: "--rag and --export-nle are mutually exclusive.",
                      agentAction: "Use one output format at a time: remove --rag to use --export-nle, or vice versa.")
            throw ExitCode(VvxExitCode.userError)
        }

        // 2 — Dry-run skips entitlement (same behaviour as gather --dry-run).
        if !dryRun {
            try await EntitlementChecker.requirePro(.nleExport)
        }

        fputs("Searching vortex.db for NLE export candidates…\n", stderr)

        // 3 — Open DB
        let db: VortexDB
        do {
            db = try VortexDB.open()
        } catch {
            emitError(code: .indexCorrupt,
                      message: "Could not open vortex.db: \(error.localizedDescription)")
            throw ExitCode(VvxExitCode.forErrorCode(.indexCorrupt))
        }

        // 4 — Search
        let hits: [SearchHit]
        do {
            hits = try await db.search(
                query:     query ?? "",
                platform:  platform,
                afterDate: after,
                uploader:  uploader,
                limit:     limit
            )
        } catch {
            emitError(code: .indexEmpty,
                      message: "Search failed: \(error.localizedDescription)")
            throw ExitCode(VvxExitCode.forErrorCode(.indexEmpty))
        }

        // 5 — Zero hits
        if hits.isEmpty {
            fputs("No results matching criteria.\n", stderr)
            printNDJSON(NleEmptySummary(query: query ?? ""))
            return
        }

        // 6 — Resolve windows via shared ClipWindowResolver
        let (resolved, warnings) = ClipWindowResolver.resolveWindows(
            hits:           hits,
            snapMode:       snap,
            contextSeconds: contextSeconds
        )
        for w in warnings { fputs(w + "\n", stderr) }

        // 7 — Partition: hits with a local file vs. missing
        var clippable: [ResolvedClip] = []
        var skipCount = 0
        var skipLineCount = 0
        let skipThrottle = 3

        for rc in resolved {
            if let path = rc.hit.videoPath, FileManager.default.fileExists(atPath: path) {
                clippable.append(rc)
            } else {
                skipCount += 1
                printNDJSON(NleSkipEntry(
                    videoId: rc.hit.videoId,
                    title:   rc.hit.title,
                    agentAction: "Run 'vvx fetch \"\(rc.hit.videoId)\" --archive' to download the source video, then retry."
                ))
                if skipLineCount < skipThrottle {
                    fputs("⚠ Skipping \(rc.hit.title) — source file not on disk (run vvx fetch \"\(rc.hit.videoId)\" --archive).\n", stderr)
                    skipLineCount += 1
                } else if skipLineCount == skipThrottle {
                    fputs("⚠ … and more clips skipped (no local file); see NDJSON for details.\n", stderr)
                    skipLineCount += 1
                }
            }
        }

        // 8 — Dry-run branch
        if dryRun {
            let plannedDur = clippable.reduce(0.0) { sum, rc in
                let padded = FFmpegRunner.paddedBounds(
                    logicalStart:  rc.resolvedStartSeconds,
                    logicalEnd:    rc.resolvedEndSeconds,
                    pad:           pad,
                    videoDuration: rc.hit.videoDurationSeconds.map { Double($0) }
                )
                return sum + (padded.end - padded.start)
            }
            printNDJSON(NleDryRunSummary(
                format:                    format.rawValue,
                plannedOutputPath:         resolvedOutputPath(outPath),
                plannedClipCount:          clippable.count,
                plannedSkipCount:          skipCount,
                plannedTotalDurationSeconds: plannedDur,
                query:                     query ?? ""
            ))
            fputs("Dry run: \(clippable.count) clip(s) planned (\(skipCount) would be skipped).\n", stderr)
            return
        }

        // 9 — All hits missing → error
        if clippable.isEmpty {
            let env = VvxErrorEnvelope(error: VvxError(code: .nleNoLocalFiles,
                message: "No search hits have a local archive file. Download sources first."))
            print(env.jsonString())
            throw ExitCode(VvxExitCode.forErrorCode(.nleNoLocalFiles))
        }

        // 10 — Apply padded bounds and build NLEClip array
        let total = clippable.count
        var nleClips: [NLEClip] = []
        var totalDuration = 0.0

        for (i, rc) in clippable.enumerated() {
            let hit    = rc.hit
            let padded = FFmpegRunner.paddedBounds(
                logicalStart:  rc.resolvedStartSeconds,
                logicalEnd:    rc.resolvedEndSeconds,
                pad:           pad,
                videoDuration: hit.videoDurationSeconds.map { Double($0) }
            )
            let clipDur = padded.end - padded.start
            totalDuration += clipDur

            let id      = GatherPathNaming.paddedClipIndex(i + 1, total: total)
            let srcPath = hit.videoPath!

            let chapterTitle: String? = hit.chapterIndex.flatMap { idx in
                guard idx >= 0, idx < hit.chapters.count else { return nil }
                return hit.chapters[idx].title
            }

            var repro = "vvx clip \"\(srcPath)\" --start \(rc.resolvedStartSeconds) --end \(rc.resolvedEndSeconds) --pad \(pad)"
            if snap != .off { repro += " --snap \(snap.rawValue)" }

            nleClips.append(NLEClip(
                id:                    id,
                sourceUrl:             hit.videoId,
                sourcePath:            srcPath,
                sourceDurationSeconds: hit.videoDurationSeconds.map { Double($0) },
                title:                 hit.title,
                uploader:              hit.uploader,
                inSeconds:             padded.start,
                outSeconds:            padded.end,
                matchedText:           String(hit.text.prefix(200)),
                chapterTitle:          chapterTitle,
                reproduceCommand:      repro
            ))
        }

        // 11 — Build NLETimeline
        let timeline = NLETimeline(
            title:     query ?? "",
            frameRate: frameRate,
            clips:     nleClips
        )

        // 12 — Write NLE export file
        let nleData: Data
        let formatLabel: String
        do {
            switch format {
            case .fcpx:
                nleData = try FCPXMLWriter.write(timeline)
                formatLabel = "FCPXML"
            case .premiere:
                nleData = try PremiereXMLWriter.write(timeline)
                formatLabel = "Premiere XML"
            case .resolve:
                nleData = try ResolveEDLWriter.write(timeline)
                formatLabel = "EDL"
            }
        } catch {
            emitError(code: .nleWriteFailed,
                      message: "\(format.rawValue.capitalized) generation failed: \(error.localizedDescription)")
            throw ExitCode(VvxExitCode.forErrorCode(.nleWriteFailed))
        }

        let resolvedOut = resolvedOutputPath(outPath)
        let outDir = (resolvedOut as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: outDir,
                                                     withIntermediateDirectories: true,
                                                     attributes: nil)
            try nleData.write(to: URL(fileURLWithPath: resolvedOut))
        } catch {
            emitError(code: .nleWriteFailed,
                      message: "Could not write \(formatLabel) file to \(resolvedOut): \(error.localizedDescription)")
            throw ExitCode(VvxExitCode.forErrorCode(.nleWriteFailed))
        }

        // 13 — Build reproduce command for summary
        var reproduceCmd = "vvx search \"\(query ?? "")\" --export-nle \(format.rawValue) --export-nle-out \(outPath) --pad \(pad) --limit \(limit)"
        if let p = platform { reproduceCmd += " --platform \"\(p)\"" }
        if let a = after    { reproduceCmd += " --after \(a)" }
        if let u = uploader { reproduceCmd += " --uploader \"\(u)\"" }
        if contextSeconds != 1.0 { reproduceCmd += " --context-seconds \(contextSeconds)" }
        if snap != .off { reproduceCmd += " --snap \(snap.rawValue)" }
        if frameRate != 29.97 { reproduceCmd += " --frame-rate \(frameRate)" }

        // 14 — Emit summary NDJSON
        printNDJSON(NleExportSummary(
            format:               format.rawValue,
            outputPath:           resolvedOut,
            clipCount:            nleClips.count,
            skippedCount:         skipCount,
            totalDurationSeconds: totalDuration,
            query:                query ?? "",
            padSeconds:           pad,
            reproduceCommand:     reproduceCmd
        ))

        let displayOut = resolvedOut.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let skipNote   = skipCount > 0 ? " (\(skipCount) skipped)" : ""
        fputs("\(formatLabel): wrote \(nleClips.count) clip(s) → \(displayOut)\(skipNote).\n", stderr)
    }

    // MARK: - Helpers

    private func resolvedOutputPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    private func reproduceCommand(videoPath: String?, start: Double, end: Double) -> String {
        guard let path = videoPath else { return "" }
        return "vvx clip \"\(path)\" --start \(start) --end \(end)"
    }

    private func emitError(code: VvxErrorCode, message: String, agentAction: String? = nil) {
        let env = VvxErrorEnvelope(error: VvxError(code: code, message: message,
                                                    agentAction: agentAction))
        print(env.jsonString())
    }
}

// MARK: - Structural search NDJSON models (CLI layer only)

private struct MonologueResultLine: Encodable {
    let success           = true
    let mode              = "longest_monologue"
    let rank:              Int
    let videoTitle:        String
    let uploader:          String?
    let platform:          String?
    let uploadDate:        String?
    let videoPath:         String?
    let startSeconds:      Double
    let endSeconds:        Double
    let durationSeconds:   Double
    let blockCount:        Int
    let structuralScore:   Double
    let transcriptExcerpt: String
    let reproduceCommand:  String
}

private struct DensityResultLine: Encodable {
    let success           = true
    let mode              = "high_density"
    let rank:              Int
    let videoTitle:        String
    let uploader:          String?
    let platform:          String?
    let uploadDate:        String?
    let videoPath:         String?
    let startSeconds:      Double
    let endSeconds:        Double
    let windowSeconds:     Double
    let wordCount:         Int
    let wordsPerSecond:    Double
    let structuralScore:   Double
    let transcriptExcerpt: String
    let reproduceCommand:  String
}

private struct StructuralSummaryLine: Encodable {
    let success       = true
    let mode:          String
    let scannedVideos: Int
    let resultCount:   Int
    let limit:         Int
    let uploader:      String?
    let platform:      String?
    let afterDate:     String?
}

// MARK: - NDJSON models (NLE export — CLI layer only)

private struct NleEmptySummary: Encodable {
    let success = true
    let totalClips = 0
    let query: String
}

private struct NleSkipEntry: Encodable {
    let success = false
    let skipped = true
    let reason  = "missing_local_file"
    let videoId: String
    let title: String
    let agentAction: String
}

private struct NleDryRunSummary: Encodable {
    let success    = true
    let dryRun     = true
    let format: String
    let plannedOutputPath: String
    let plannedClipCount: Int
    let plannedSkipCount: Int
    let plannedTotalDurationSeconds: Double
    let query: String
}

private struct NleExportSummary: Encodable {
    let success = true
    let format: String
    let outputPath: String
    let clipCount: Int
    let skippedCount: Int
    let totalDurationSeconds: Double
    let query: String
    let padSeconds: Double
    let reproduceCommand: String
}

// MARK: - Error envelope

/// Minimal failure envelope so agents always receive valid JSON from `vvx search`.
private struct SearchErrorEnvelope: Codable {
    var success: Bool
    var query: String
    var totalMatches: Int
    var results: [String]
    var error: String

    init(query: String, message: String) {
        self.success      = false
        self.query        = query
        self.totalMatches = 0
        self.results      = []
        self.error        = message
    }

    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let str  = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - Helpers

private func printNDJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
