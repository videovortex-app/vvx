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
          vvx search "neuralink" --export-nle fcpx --export-nle-out ~/Desktop/cuts.fcpxml
          Opens in Final Cut Pro as a ready-to-cut project referencing archive files
          in-place — zero re-encode, zero extra storage, infinite handles.

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
        """
    )

    // MARK: - Base search flags

    @Argument(help: "The search query. Supports FTS5 syntax: AND, OR, NOT, phrase, prefix*.")
    var query: String

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

    // MARK: - NLE export flags (Step 6)

    @Option(name: .customLong("export-nle"),
            help: "NLE export format. Step 6 supports 'fcpx' (Final Cut Pro XML). Requires --export-nle-out.")
    var exportNle: NleExportFormat?

    @Option(name: .customLong("export-nle-out"),
            help: "Output path for the NLE export file (e.g. ~/Desktop/cuts.fcpxml). Required with --export-nle.")
    var exportNleOut: String?

    @Option(name: .long,
            help: "Seconds of handle before/after each cue; written as source in/out timecodes in FCPXML (default: 2.0).")
    var pad: Double = 2.0

    @Option(name: .customLong("context-seconds"),
            help: "Seconds of context around each matched cue before snap resolution (default: 1.0). Only applies to NLE export.")
    var contextSeconds: Double = 1.0

    @Option(name: .long,
            help: "Clip window snap mode: off (cue + context), block (exact cue), chapter (full chapter span). Default: off.")
    var snap: SnapMode = .off

    @Option(name: .customLong("frame-rate"),
            help: "FCPXML sequence ruler frame rate (default: 29.97). Does not affect clip trim accuracy.")
    var frameRate: Double = 29.97

    @Flag(name: .long,
          help: "Print planned clip list without writing the FCPXML file.")
    var dryRun: Bool = false

    // MARK: - Run

    mutating func run() async throws {

        // --- NLE export branch --------------------------------------------------
        if exportNle != nil || exportNleOut != nil {
            try await runNLEExport()
            return
        }

        // --- Standard JSON / RAG branch -----------------------------------------
        guard maxTokens == nil || rag else {
            printNDJSON(SearchErrorEnvelope(
                query: query,
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
                query:   query,
                message: "Could not open vortex.db: \(error.localizedDescription)"
            )
            printNDJSON(envelope)
            throw ExitCode(1)
        }

        let output: SearchOutput
        do {
            output = try await SRTSearcher.search(
                query:     query,
                db:        db,
                platform:  platform,
                afterDate: after,
                uploader:  uploader,
                limit:     limit
            )
        } catch {
            let envelope = SearchErrorEnvelope(
                query:   query,
                message: "Search failed: \(error.localizedDescription)"
            )
            printNDJSON(envelope)
            throw ExitCode(1)
        }

        fputs("Found \(output.totalMatches) result(s).\n", stderr)

        if rag {
            let markdown = SRTSearcher.ragMarkdown(
                query:              query,
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

    // MARK: - NLE export run

    private mutating func runNLEExport() async throws {

        // 1 — Flag validation
        guard let format = exportNle else {
            emitError(code: .parseError,
                      message: "--export-nle-out requires --export-nle <format>.",
                      agentAction: "Add --export-nle fcpx to your command.")
            throw ExitCode(VvxExitCode.userError)
        }
        guard let outPath = exportNleOut else {
            emitError(code: .parseError,
                      message: "--export-nle requires --export-nle-out <path>.",
                      agentAction: "Add --export-nle-out ~/Desktop/output.fcpxml to your command.")
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
                query:     query,
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
            printNDJSON(NleEmptySummary(query: query))
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
                query:                     query
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

            // Chapter title when the hit has chapter metadata
            let chapterTitle: String? = hit.chapterIndex.flatMap { idx in
                guard idx >= 0, idx < hit.chapters.count else { return nil }
                return hit.chapters[idx].title
            }

            // Reproduce command
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
            title:     query,
            frameRate: frameRate,
            clips:     nleClips
        )

        // 12 — Write FCPXML
        let xmlData: Data
        do {
            switch format {
            case .fcpx:
                xmlData = try FCPXMLWriter.write(timeline)
            }
        } catch {
            emitError(code: .nleWriteFailed,
                      message: "FCPXML generation failed: \(error.localizedDescription)")
            throw ExitCode(VvxExitCode.forErrorCode(.nleWriteFailed))
        }

        let resolvedOut = resolvedOutputPath(outPath)
        let outDir = (resolvedOut as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: outDir,
                                                     withIntermediateDirectories: true,
                                                     attributes: nil)
            try xmlData.write(to: URL(fileURLWithPath: resolvedOut))
        } catch {
            emitError(code: .nleWriteFailed,
                      message: "Could not write FCPXML to \(resolvedOut): \(error.localizedDescription)")
            throw ExitCode(VvxExitCode.forErrorCode(.nleWriteFailed))
        }

        // 13 — Build reproduce command for summary
        var reproduceCmd = "vvx search \"\(query)\" --export-nle \(format.rawValue) --export-nle-out \(outPath) --pad \(pad) --limit \(limit)"
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
            query:                query,
            padSeconds:           pad,
            reproduceCommand:     reproduceCmd
        ))

        let displayOut = resolvedOut.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let skipNote   = skipCount > 0 ? " (\(skipCount) skipped)" : ""
        fputs("FCPXML: wrote \(nleClips.count) clip(s) → \(displayOut)\(skipNote).\n", stderr)
    }

    // MARK: - Helpers

    private func resolvedOutputPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    private func emitError(code: VvxErrorCode, message: String, agentAction: String? = nil) {
        let env = VvxErrorEnvelope(error: VvxError(code: code, message: message,
                                                    agentAction: agentAction))
        print(env.jsonString())
    }
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
