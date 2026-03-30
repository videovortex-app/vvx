import Foundation

// MARK: - Internal plan + outcome types (not exported)

struct GatherClipPlan: Sendable {
    let resolved:         ResolvedClip
    let outputPath:       String
    let index:            Int
    let total:            Int
    /// Non-nil when `embedSource` is on; carries title/artist/comment for this clip.
    let sourceMetadata:   SourceMetadata?
    let extractThumbnail: Bool
}

enum GatherWorkerOutcome: Sendable {
    case success(SuccessPayload)
    case failure(FailurePayload)

    struct SuccessPayload: Sendable {
        let plan:               GatherClipPlan
        let clipResult:         ClipResult
        let sizeBytes:          Int64?
        let elapsed:            TimeInterval
        let thumbnailPath:      String?
        let embedSourceApplied: Bool
        let encodeMode:         String
    }

    struct FailurePayload: Sendable {
        let plan:    GatherClipPlan
        let error:   VvxError
        let elapsed: TimeInterval
    }
}

// MARK: - Line collector actor

private actor GatherLineCollector {
    private var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    func joined() -> String    { lines.joined(separator: "\n") }
}

// MARK: - GatherConfig

public struct GatherConfig: Sendable {
    // Search
    public let query:             String
    public let limit:             Int
    public let platform:          String?
    public let after:             String?
    public let uploader:          String?
    public let minViews:          Int?
    public let minLikes:          Int?
    public let minComments:       Int?
    // Boundary
    public let contextSeconds:    Double         // default: 1.0
    public let snapMode:          SnapMode       // default: .off
    public let maxTotalDuration:  Double?
    public let pad:               Double         // default: 2.0
    // Extraction
    public let dryRun:            Bool           // default: false
    public let fast:              Bool           // default: false
    public let exact:             Bool           // default: false
    public let thumbnails:        Bool           // default: false
    public let embedSource:       Bool           // default: false
    public let chaptersOnly:      Bool           // default: false
    // Output
    /// nil = auto-name: ~/Desktop/Gather_<query>_<timestamp>
    public let outputDir:         String?

    public init(
        query: String, limit: Int, platform: String? = nil,
        after: String? = nil, uploader: String? = nil,
        minViews: Int? = nil, minLikes: Int? = nil, minComments: Int? = nil,
        contextSeconds: Double = 1.0, snapMode: SnapMode = .off,
        maxTotalDuration: Double? = nil, pad: Double = 2.0,
        dryRun: Bool = false, fast: Bool = false, exact: Bool = false,
        thumbnails: Bool = false, embedSource: Bool = false,
        chaptersOnly: Bool = false, outputDir: String? = nil
    ) {
        self.query            = query
        self.limit            = limit
        self.platform         = platform
        self.after            = after
        self.uploader         = uploader
        self.minViews         = minViews
        self.minLikes         = minLikes
        self.minComments      = minComments
        self.contextSeconds   = contextSeconds
        self.snapMode         = snapMode
        self.maxTotalDuration = maxTotalDuration
        self.pad              = pad
        self.dryRun           = dryRun
        self.fast             = fast
        self.exact            = exact
        self.thumbnails       = thumbnails
        self.embedSource      = embedSource
        self.chaptersOnly     = chaptersOnly
        self.outputDir        = outputDir
    }
}

// MARK: - GatherEngine

public enum GatherEngine {

    /// Run a full gather operation and return the aggregated NDJSON string.
    ///
    /// - Parameters:
    ///   - config:   All gather flags.
    ///   - progress: Optional stderr-style progress callback. CLI passes `{ stderrLine($0) }`.
    ///               MCP passes `nil`.
    /// - Returns: Newline-joined NDJSON lines. Last line is always `GatherSummaryLine`.
    ///   On tool-level errors (DB failure, ffmpeg not found), returns a single
    ///   `VvxErrorEnvelope` JSON string — does NOT throw.
    public static func run(
        config:   GatherConfig,
        progress: ((String) -> Void)? = nil
    ) async -> String {
        let collector     = GatherLineCollector()
        let resolvedDir   = resolveOutputDirectory(config: config)
        let encodeMode    = config.fast ? "copy" : (config.exact ? "exact" : "default")

        // chaptersOnly branch — delegated to separate method
        if config.chaptersOnly {
            if config.contextSeconds != 1.0 {
                progress?("Note: --context-seconds is ignored with --chapters-only; chapter boundaries are used directly.")
            }
            let db: VortexDB
            do { db = try VortexDB.open() } catch {
                return VvxErrorEnvelope(error: VvxError(
                    code: .indexCorrupt,
                    message: "Could not open vortex.db: \(error.localizedDescription)"
                )).jsonString()
            }
            return await runChaptersOnly(
                config:     config,
                db:         db,
                collector:  collector,
                progress:   progress,
                outputDir:  resolvedDir,
                encodeMode: encodeMode
            )
        }

        progress?("Searching vortex.db for gather candidates…")

        // Open DB
        let db: VortexDB
        do { db = try VortexDB.open() } catch {
            return VvxErrorEnvelope(error: VvxError(
                code: .indexCorrupt,
                message: "Could not open vortex.db: \(error.localizedDescription)"
            )).jsonString()
        }

        // Resolve ffmpeg (skip for dry-run)
        let ffmpegURL: URL?
        if !config.dryRun {
            ffmpegURL = EngineResolver.cliResolver.resolvedFfmpegURL()
            guard ffmpegURL != nil else {
                return VvxErrorEnvelope(error: VvxError(
                    code: .ffmpegNotFound,
                    message: "ffmpeg is required for clip extraction."
                )).jsonString()
            }
        } else {
            ffmpegURL = nil
        }

        // FTS search with engagement filters
        let hits: [SearchHit]
        do {
            hits = try await db.search(
                query:       config.query,
                platform:    config.platform,
                afterDate:   config.after,
                uploader:    config.uploader,
                minViews:    config.minViews,
                minLikes:    config.minLikes,
                minComments: config.minComments,
                limit:       config.limit
            )
        } catch {
            return VvxErrorEnvelope(error: VvxError(
                code: .indexEmpty,
                message: "Search failed: \(error.localizedDescription)"
            )).jsonString()
        }

        // Zero hits
        if hits.isEmpty {
            progress?("No clips matching criteria.")
            await collector.append(encode(GatherEmptySummary(query: config.query)))
            await collector.append(encode(GatherSummaryLine(
                succeeded: 0, failed: 0, total: 0, dryRun: config.dryRun,
                outputDir: resolvedDir, manifestPath: nil
            )))
            return await collector.joined()
        }

        // Resolve windows via ClipWindowResolver; forward warnings to progress
        let (resolved, resolveWarnings) = ClipWindowResolver.resolveWindows(
            hits:           hits,
            snapMode:       config.snapMode,
            contextSeconds: config.contextSeconds
        )
        for w in resolveWarnings { progress?(w) }

        // Partition: clippable vs VIDEO_UNAVAILABLE
        var clippable: [ResolvedClip] = []
        var unavailableCount = 0

        for rc in resolved {
            if let path = rc.hit.videoPath, FileManager.default.fileExists(atPath: path) {
                clippable.append(rc)
            } else {
                unavailableCount += 1
                await collector.append(encode(GatherClipFailure(
                    error: VvxError(
                        code: .videoUnavailable,
                        message: "Source video not on disk for \(rc.hit.videoId). Download it first.",
                        agentAction: "Run 'vvx fetch \"\(rc.hit.videoId)\" --archive' to download the video, then retry gather."
                    ),
                    videoId:   rc.hit.videoId,
                    startTime: rc.hit.startTime,
                    endTime:   rc.hit.endTime
                )))
            }
        }

        let skipNote = unavailableCount > 0 ? " (\(unavailableCount) skipped — no local file)" : ""
        progress?("Found \(resolved.count) clip(s) matching criteria.\(skipNote)")

        if clippable.isEmpty {
            await collector.append(encode(GatherSummaryLine(
                succeeded: 0, failed: unavailableCount, total: unavailableCount,
                dryRun: config.dryRun, outputDir: resolvedDir, manifestPath: nil
            )))
            return await collector.joined()
        }

        // Apply budget cap (--max-total-duration)
        let (budgetClippable, budgetSkipped) = ClipWindowResolver.applyBudgetCap(
            clippable,
            maxTotalDuration: config.maxTotalDuration
        )

        for bs in budgetSkipped {
            await collector.append(encode(GatherBudgetSkipEntry(
                videoId:                bs.hit.videoId,
                startTime:              bs.hit.startTime,
                endTime:                bs.hit.endTime,
                plannedDurationSeconds: bs.plannedDuration
            )))
        }

        if !budgetSkipped.isEmpty {
            progress?("Budget: skipped \(budgetSkipped.count) clip(s) to stay under --max-total-duration (lower-relevance hits dropped first).")
        }

        if budgetClippable.isEmpty {
            await collector.append(encode(GatherSummaryLine(
                succeeded: 0, failed: unavailableCount, total: unavailableCount,
                dryRun: config.dryRun, outputDir: resolvedDir, manifestPath: nil
            )))
            return await collector.joined()
        }

        // Output directory
        if !config.dryRun {
            do {
                try FileManager.default.createDirectory(
                    atPath: resolvedDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                return VvxErrorEnvelope(error: VvxError(
                    code: .permissionDenied,
                    message: "Could not create output directory: \(error.localizedDescription)"
                )).jsonString()
            }
        }

        // Build clip plans
        let plans = buildClipPlans(resolved: budgetClippable, outputDir: resolvedDir, config: config)

        // Dry-run branch
        if config.dryRun {
            var drySucceeded = 0
            for plan in plans {
                let rc     = plan.resolved
                let padded = FFmpegRunner.paddedBounds(
                    logicalStart:  rc.resolvedStartSeconds,
                    logicalEnd:    rc.resolvedEndSeconds,
                    pad:           config.pad,
                    videoDuration: rc.hit.videoDurationSeconds.map { Double($0) }
                )
                let srtPlan   = (plan.outputPath as NSString).deletingPathExtension + ".srt"
                let thumbPlan = config.thumbnails
                    ? ((plan.outputPath as NSString).deletingPathExtension + ".jpg")
                    : nil
                await collector.append(encode(GatherDryRunEntry(
                    plannedOutputPath:      plan.outputPath,
                    inputPath:              rc.hit.videoPath ?? "",
                    videoId:                rc.hit.videoId,
                    title:                  rc.hit.title,
                    uploader:               rc.hit.uploader,
                    startTime:              TimeParser.formatHHMMSS(rc.resolvedStartSeconds),
                    endTime:                TimeParser.formatHHMMSS(rc.resolvedEndSeconds),
                    resolvedStartSeconds:   rc.resolvedStartSeconds,
                    resolvedEndSeconds:     rc.resolvedEndSeconds,
                    padSeconds:             config.pad,
                    paddedStartSeconds:     padded.start,
                    paddedEndSeconds:       padded.end,
                    plannedDurationSeconds: padded.end - padded.start,
                    plannedSrtPath:         srtPlan,
                    matchedText:            String(rc.hit.text.prefix(200)),
                    snapApplied:            rc.snapApplied.rawValue,
                    plannedThumbnailPath:   thumbPlan,
                    embedSourcePlanned:     config.embedSource,
                    encodeMode:             encodeMode,
                    chapterTitle:           rc.hit.chapterIndex.flatMap { idx in
                        guard idx >= 0, idx < rc.hit.chapters.count else { return nil }
                        return rc.hit.chapters[idx].title
                    },
                    chapterIndex:           rc.hit.chapterIndex
                )))
                drySucceeded += 1
            }
            progress?("Dry run: \(plans.count) clip(s) planned\(skipNote).")
            await collector.append(encode(GatherSummaryLine(
                succeeded: drySucceeded, failed: unavailableCount,
                total: drySucceeded + unavailableCount,
                dryRun: true, outputDir: resolvedDir, manifestPath: nil
            )))
            return await collector.joined()
        }

        // Extraction loop (max 4 concurrent)
        let displayDir = resolvedDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        progress?("Extracting \(plans.count) clip(s) → \(displayDir)")

        let resolvedFfmpeg = ffmpegURL!
        var succeeded      = 0
        var extractFailed  = 0
        var completed      = 0
        let totalPlans     = plans.count
        var successPayloads: [GatherWorkerOutcome.SuccessPayload] = []

        await withTaskGroup(of: GatherWorkerOutcome.self) { group in
            var active = 0

            for plan in plans {
                if active >= 4 {
                    if let outcome = await group.next() {
                        completed += 1
                        let (ok, fail) = await Self.processOutcome(
                            outcome, completed: completed, total: totalPlans,
                            pad: config.pad, collector: collector, progress: progress
                        )
                        if ok   { succeeded += 1 }
                        if fail { extractFailed += 1 }
                        if case .success(let p) = outcome { successPayloads.append(p) }
                    }
                    active -= 1
                }

                let captured      = plan
                let useFast       = config.fast
                let useExact      = config.exact
                let useThumbnails = config.thumbnails
                let padValue      = config.pad
                group.addTask {
                    await Self.extractClip(
                        plan:       captured,
                        ffmpegPath: resolvedFfmpeg,
                        fast:       useFast,
                        exact:      useExact,
                        pad:        padValue,
                        thumbnails: useThumbnails
                    )
                }
                active += 1
            }

            for await outcome in group {
                completed += 1
                let (ok, fail) = await Self.processOutcome(
                    outcome, completed: completed, total: totalPlans,
                    pad: config.pad, collector: collector, progress: progress
                )
                if ok   { succeeded += 1 }
                if fail { extractFailed += 1 }
                if case .success(let p) = outcome { successPayloads.append(p) }
            }
        }

        let failNote = extractFailed > 0 ? ", \(extractFailed) failed" : ""
        progress?("Done. \(succeeded)/\(totalPlans) clip(s) extracted\(failNote).")

        // Write sidecars for all successful clips
        var manifestPath: String? = nil
        if !successPayloads.isEmpty {
            successPayloads.sort { $0.plan.index < $1.plan.index }
            manifestPath = await writeSidecars(
                successPayloads: successPayloads,
                db:              db,
                outputDir:       resolvedDir,
                config:          config,
                encodeMode:      encodeMode,
                progress:        progress
            )
        }

        // Thumbnail summary
        if config.thumbnails && !successPayloads.isEmpty {
            let written    = successPayloads.filter { $0.thumbnailPath != nil }.count
            let failedThumb = successPayloads.count - written
            if written > 0     { progress?("Thumbnails: wrote \(written) image(s).") }
            if failedThumb > 0 { progress?("⚠ Thumbnails: \(failedThumb) image(s) could not be extracted.") }
        }

        let totalFailed = unavailableCount + extractFailed
        await collector.append(encode(GatherSummaryLine(
            succeeded:    succeeded,
            failed:       totalFailed,
            total:        succeeded + totalFailed,
            dryRun:       false,
            outputDir:    resolvedDir,
            manifestPath: manifestPath
        )))
        return await collector.joined()
    }

    // MARK: - Chapters-only path

    private static func runChaptersOnly(
        config:     GatherConfig,
        db:         VortexDB,
        collector:  GatherLineCollector,
        progress:   ((String) -> Void)?,
        outputDir:  String,
        encodeMode: String
    ) async -> String {
        let terms = config.query
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        let summaries: [VideoSummary]
        do {
            summaries = try await db.videoSummaries(
                platform:  config.platform,
                uploader:  config.uploader,
                afterDate: config.after
            )
        } catch {
            return VvxErrorEnvelope(error: VvxError(
                code: .indexCorrupt,
                message: "Could not query videos: \(error.localizedDescription)"
            )).jsonString()
        }

        progress?("Scanning \(summaries.count) video(s) for chapter title matches…")

        struct ChapterMatch {
            let summary:      VideoSummary
            let chapter:      VideoChapter
            let chapterIndex: Int
            let termCount:    Int
        }

        var matches: [ChapterMatch] = []
        for summary in summaries {
            for (idx, chapter) in summary.chapters.enumerated() {
                let lowerTitle   = chapter.title.lowercased()
                let matchedTerms = terms.filter { lowerTitle.contains($0.lowercased()) }
                if matchedTerms.count == terms.count {
                    matches.append(ChapterMatch(
                        summary:      summary,
                        chapter:      chapter,
                        chapterIndex: idx,
                        termCount:    matchedTerms.count
                    ))
                }
            }
        }

        if matches.isEmpty {
            progress?("No chapter titles matched \"\(config.query)\". Try broader terms or use vvx gather without --chapters-only.")
            await collector.append(encode(GatherEmptySummary(query: config.query)))
            await collector.append(encode(GatherSummaryLine(
                succeeded: 0, failed: 0, total: 0, dryRun: config.dryRun,
                outputDir: outputDir, manifestPath: nil
            )))
            return await collector.joined()
        }

        matches.sort {
            if $0.termCount != $1.termCount { return $0.termCount > $1.termCount }
            if $0.summary.id == $1.summary.id { return $0.chapter.startTime < $1.chapter.startTime }
            return false
        }

        let topMatches = Array(matches.prefix(config.limit))

        if !config.dryRun {
            do {
                try FileManager.default.createDirectory(
                    atPath: outputDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                return VvxErrorEnvelope(error: VvxError(
                    code: .permissionDenied,
                    message: "Could not create output directory: \(error.localizedDescription)"
                )).jsonString()
            }
        }

        let ffmpegURL: URL?
        if !config.dryRun {
            ffmpegURL = EngineResolver.cliResolver.resolvedFfmpegURL()
            guard ffmpegURL != nil else {
                return VvxErrorEnvelope(error: VvxError(
                    code: .ffmpegNotFound,
                    message: "ffmpeg is required for clip extraction."
                )).jsonString()
            }
        } else {
            ffmpegURL = nil
        }

        var succeeded = 0
        var failCount = 0

        for (i, m) in topMatches.enumerated() {
            let rank = i + 1
            guard let videoPath = m.summary.videoPath,
                  FileManager.default.fileExists(atPath: videoPath) else {
                progress?("[\(rank)/\(topMatches.count)] ⚠ Skipping '\(m.chapter.title)' — source file not on disk.")
                await collector.append(encode(GatherClipFailure(
                    error: VvxError(
                        code: .videoUnavailable,
                        message: "Source video not on disk for \(m.summary.id). Download it first.",
                        agentAction: "Run 'vvx fetch \"\(m.summary.id)\" --archive' to download the video, then retry gather."
                    ),
                    videoId:   m.summary.id,
                    startTime: TimeParser.formatHHMMSS(m.chapter.startTime),
                    endTime:   ""
                )))
                failCount += 1
                continue
            }

            let startSecs = m.chapter.startTime
            let endSecs: Double
            let chapters = m.summary.chapters
            if m.chapterIndex + 1 < chapters.count {
                endSecs = chapters[m.chapterIndex + 1].startTime
            } else if let dur = m.summary.durationSeconds {
                endSecs = Double(dur)
            } else {
                progress?("[\(rank)/\(topMatches.count)] ⚠ Skipping '\(m.chapter.title)' — unknown chapter end time (last chapter, no duration).")
                failCount += 1
                continue
            }

            let paddedStart = max(0, startSecs - config.pad)
            let paddedEnd   = endSecs + config.pad
            let dur         = endSecs - startSecs
            let startFmt    = TimeParser.formatHHMMSS(startSecs)
            let endFmt      = TimeParser.formatHHMMSS(endSecs)

            let safeTitle  = GatherPathNaming.sanitizeFolderQuery(m.summary.title)
            let filename   = "\(GatherPathNaming.paddedClipIndex(rank, total: topMatches.count))_\(safeTitle)_ch\(m.chapterIndex)_\(TimeParser.formatCompact(startSecs)).mp4"
            let outputPath = (outputDir as NSString).appendingPathComponent(filename)
            let srtPlan    = (outputPath as NSString).deletingPathExtension + ".srt"

            if config.dryRun {
                await collector.append(encode(GatherDryRunEntry(
                    plannedOutputPath:      outputPath,
                    inputPath:              videoPath,
                    videoId:                m.summary.id,
                    title:                  m.summary.title,
                    uploader:               m.summary.uploader,
                    startTime:              startFmt,
                    endTime:                endFmt,
                    resolvedStartSeconds:   startSecs,
                    resolvedEndSeconds:     endSecs,
                    padSeconds:             config.pad,
                    paddedStartSeconds:     paddedStart,
                    paddedEndSeconds:       paddedEnd,
                    plannedDurationSeconds: dur + config.pad * 2,
                    plannedSrtPath:         srtPlan,
                    matchedText:            "",
                    snapApplied:            "chapter",
                    plannedThumbnailPath:   nil,
                    embedSourcePlanned:     config.embedSource,
                    encodeMode:             encodeMode,
                    chapterTitle:           m.chapter.title,
                    chapterIndex:           m.chapterIndex
                )))
                succeeded += 1
                continue
            }

            do {
                let result = try await FFmpegRunner.clip(
                    ffmpegPath:    ffmpegURL!,
                    inputPath:     videoPath,
                    start:         startSecs,
                    end:           endSecs,
                    outputPath:    outputPath,
                    fast:          config.fast,
                    exact:         config.exact,
                    pad:           config.pad,
                    videoDuration: m.summary.durationSeconds.map { Double($0) },
                    metadata:      nil
                )

                let size = try? FileManager.default.attributesOfItem(atPath: result.outputPath)[.size] as? Int64
                progress?("[\(rank)/\(topMatches.count)] ✓ \(m.summary.uploader ?? m.summary.title) — \(startFmt)→\(endFmt)")

                let blocks = (try? await db.blocksForVideo(videoId: m.summary.id)) ?? []
                if !blocks.isEmpty,
                   let srtContent = SRTRetimer.retimed(blocks: blocks, paddedStart: result.startSeconds, paddedEnd: result.endSeconds) {
                    try? srtContent.write(toFile: srtPlan, atomically: true, encoding: .utf8)
                }

                await collector.append(encode(GatherClipSuccess(
                    outputPath:           result.outputPath,
                    inputPath:            result.inputPath,
                    videoId:              m.summary.id,
                    title:                m.summary.title,
                    uploader:             m.summary.uploader,
                    startTime:            startFmt,
                    endTime:              endFmt,
                    durationSeconds:      result.durationSeconds,
                    resolvedStartSeconds: startSecs,
                    resolvedEndSeconds:   endSecs,
                    padSeconds:           config.pad,
                    paddedStartSeconds:   result.startSeconds,
                    paddedEndSeconds:     result.endSeconds,
                    plannedSrtPath:       srtPlan,
                    matchedText:          "",
                    method:               result.method,
                    sizeBytes:            size,
                    snapApplied:          "chapter",
                    thumbnailPath:        nil,
                    embedSourceApplied:   false,
                    embedSourceNote:      nil,
                    encodeMode:           encodeMode,
                    chapterTitle:         m.chapter.title,
                    chapterIndex:         m.chapterIndex
                )))
                succeeded += 1
            } catch {
                progress?("[\(rank)/\(topMatches.count)] ✗ \(m.chapter.title) — extraction failed: \(error.localizedDescription)")
                await collector.append(encode(GatherClipFailure(
                    error: VvxError(code: .clipFailed, message: "Clip extraction failed: \(error.localizedDescription)"),
                    videoId:   m.summary.id,
                    startTime: startFmt,
                    endTime:   endFmt
                )))
                failCount += 1
            }
        }

        progress?("Gathered \(succeeded) chapter clip(s). \(failCount) failed.")
        if config.dryRun { progress?("Dry run: \(succeeded) clip(s) planned.") }

        await collector.append(encode(GatherSummaryLine(
            succeeded: succeeded, failed: failCount,
            total: succeeded + failCount, dryRun: config.dryRun,
            outputDir: outputDir, manifestPath: nil
        )))
        return await collector.joined()
    }

    // MARK: - Outcome processing (parent-side, sequential)

    private static func processOutcome(
        _ outcome: GatherWorkerOutcome,
        completed: Int,
        total:     Int,
        pad:       Double,
        collector: GatherLineCollector,
        progress:  ((String) -> Void)?
    ) async -> (succeeded: Bool, failed: Bool) {
        switch outcome {
        case .success(let p):
            let startFmt = TimeParser.formatHHMMSS(p.clipResult.startSeconds)
            let endFmt   = TimeParser.formatHHMMSS(p.clipResult.endSeconds)
            let label    = p.plan.resolved.hit.uploader ?? p.plan.resolved.hit.title
            progress?("[\(completed)/\(total)] ✓ \(label) — \(startFmt)→\(endFmt) (\(String(format: "%.1f", p.elapsed))s)")

            let srtPlan = (p.plan.outputPath as NSString).deletingPathExtension + ".srt"
            await collector.append(encode(GatherClipSuccess(
                outputPath:           p.clipResult.outputPath,
                inputPath:            p.clipResult.inputPath,
                videoId:              p.plan.resolved.hit.videoId,
                title:                p.plan.resolved.hit.title,
                uploader:             p.plan.resolved.hit.uploader,
                startTime:            TimeParser.formatHHMMSS(p.clipResult.startSeconds),
                endTime:              TimeParser.formatHHMMSS(p.clipResult.endSeconds),
                durationSeconds:      p.clipResult.durationSeconds,
                resolvedStartSeconds: p.plan.resolved.resolvedStartSeconds,
                resolvedEndSeconds:   p.plan.resolved.resolvedEndSeconds,
                padSeconds:           pad,
                paddedStartSeconds:   p.clipResult.startSeconds,
                paddedEndSeconds:     p.clipResult.endSeconds,
                plannedSrtPath:       srtPlan,
                matchedText:          String(p.plan.resolved.hit.text.prefix(200)),
                method:               p.clipResult.method,
                sizeBytes:            p.sizeBytes,
                snapApplied:          p.plan.resolved.snapApplied.rawValue,
                thumbnailPath:        p.thumbnailPath,
                embedSourceApplied:   p.embedSourceApplied,
                embedSourceNote:      nil,
                encodeMode:           p.encodeMode,
                chapterTitle:         p.plan.resolved.hit.chapterIndex.flatMap { idx in
                    guard idx >= 0, idx < p.plan.resolved.hit.chapters.count else { return nil }
                    return p.plan.resolved.hit.chapters[idx].title
                },
                chapterIndex:         p.plan.resolved.hit.chapterIndex
            )))
            return (true, false)

        case .failure(let p):
            let startFmt = TimeParser.formatHHMMSS(p.plan.resolved.resolvedStartSeconds)
            let label    = p.plan.resolved.hit.uploader ?? p.plan.resolved.hit.title
            progress?("[\(completed)/\(total)] ✗ \(label) — \(startFmt) (\(p.error.message))")

            await collector.append(encode(GatherClipFailure(
                error:     p.error,
                videoId:   p.plan.resolved.hit.videoId,
                startTime: p.plan.resolved.hit.startTime,
                endTime:   p.plan.resolved.hit.endTime
            )))
            return (false, true)
        }
    }

    // MARK: - Clip worker (runs inside TaskGroup child — no I/O side-effects)

    private static func extractClip(
        plan:       GatherClipPlan,
        ffmpegPath: URL,
        fast:       Bool,
        exact:      Bool,
        pad:        Double,
        thumbnails: Bool
    ) async -> GatherWorkerOutcome {
        let wallStart  = Date()
        let rc         = plan.resolved
        let clipEncode = fast ? "copy" : (exact ? "exact" : "default")

        do {
            let result = try await FFmpegRunner.clip(
                ffmpegPath:    ffmpegPath,
                inputPath:     rc.hit.videoPath!,
                start:         rc.resolvedStartSeconds,
                end:           rc.resolvedEndSeconds,
                outputPath:    plan.outputPath,
                fast:          fast,
                exact:         exact,
                pad:           pad,
                videoDuration: rc.hit.videoDurationSeconds.map { Double($0) },
                metadata:      plan.sourceMetadata
            )

            var thumbPath: String? = nil
            if thumbnails, let srcPath = rc.hit.videoPath {
                let planned = (plan.outputPath as NSString).deletingPathExtension + ".jpg"
                do {
                    try await FFmpegRunner.thumbnail(
                        ffmpegPath: ffmpegPath,
                        inputPath:  srcPath,
                        atSeconds:  rc.resolvedStartSeconds,
                        outputPath: planned
                    )
                    thumbPath = planned
                } catch {
                    // Soft-fail: thumbnail failure never fails the clip row.
                }
            }

            let elapsed = Date().timeIntervalSince(wallStart)
            let size    = try? FileManager.default.attributesOfItem(atPath: result.outputPath)[.size] as? Int64
            return .success(.init(
                plan:               plan,
                clipResult:         result,
                sizeBytes:          size,
                elapsed:            elapsed,
                thumbnailPath:      thumbPath,
                embedSourceApplied: plan.sourceMetadata != nil,
                encodeMode:         clipEncode
            ))
        } catch let err as FFmpegRunner.ClipError {
            let elapsed = Date().timeIntervalSince(wallStart)
            let vvxErr: VvxError
            switch err {
            case .ffmpegFailed(let code, let stderrText):
                vvxErr = VvxError(
                    code: .clipFailed,
                    message: "ffmpeg failed (exit \(code)).",
                    detail: String(stderrText.suffix(300))
                )
            case .inputNotFound(let path):
                vvxErr = VvxError(
                    code: .videoUnavailable,
                    message: "Input file not found: \(path)",
                    agentAction: "Run 'vvx fetch \"\(plan.resolved.hit.videoId)\" --archive' to download the video, then retry gather."
                )
            case .outputRenameFailed:
                vvxErr = VvxError(
                    code: .permissionDenied,
                    message: "Could not write output file to \(plan.outputPath)."
                )
            }
            return .failure(.init(plan: plan, error: vvxErr, elapsed: elapsed))
        } catch {
            let elapsed = Date().timeIntervalSince(wallStart)
            return .failure(.init(
                plan:    plan,
                error:   VvxError(code: .clipFailed, message: "Clip extraction failed: \(error.localizedDescription)"),
                elapsed: elapsed
            ))
        }
    }

    // MARK: - Sidecar writing (post-extraction, sequential)

    /// Returns the manifest path on success, nil on failure.
    private static func writeSidecars(
        successPayloads: [GatherWorkerOutcome.SuccessPayload],
        db:              VortexDB,
        outputDir:       String,
        config:          GatherConfig,
        encodeMode:      String,
        progress:        ((String) -> Void)?
    ) async -> String? {
        var manifestClips: [GatherManifestClip] = []
        var padClampedCount = 0

        for p in successPayloads {
            let rc          = p.plan.resolved
            let hit         = rc.hit
            let paddedStart = p.clipResult.startSeconds
            let paddedEnd   = p.clipResult.endSeconds

            if rc.resolvedStartSeconds - config.pad < -0.001 { padClampedCount += 1 }

            let blocks = (try? await db.blocksForVideo(videoId: hit.videoId)) ?? []
            let srtPathAbs: String?
            let transcriptSource: String

            if blocks.isEmpty {
                srtPathAbs       = nil
                transcriptSource = "none"
            } else if let srtContent = SRTRetimer.retimed(
                blocks: blocks, paddedStart: paddedStart, paddedEnd: paddedEnd
            ) {
                let srtPath = (p.plan.outputPath as NSString).deletingPathExtension + ".srt"
                do {
                    try srtContent.write(toFile: srtPath, atomically: true, encoding: .utf8)
                    srtPathAbs = srtPath
                } catch {
                    progress?("⚠ Could not write SRT for \(hit.videoId): \(error.localizedDescription)")
                    srtPathAbs = nil
                }
                transcriptSource = "local"
            } else {
                srtPathAbs       = nil
                transcriptSource = "local"
            }

            let mp4Filename   = URL(fileURLWithPath: p.plan.outputPath).lastPathComponent
            let srtFilename   = srtPathAbs.map { URL(fileURLWithPath: $0).lastPathComponent }
            let thumbFilename = p.thumbnailPath.map { URL(fileURLWithPath: $0).lastPathComponent }

            let srcPath = hit.videoPath ?? "UNKNOWN_PATH"
            var reproducCmd = "vvx clip \"\(srcPath)\" --start \(rc.resolvedStartSeconds) --end \(rc.resolvedEndSeconds) --pad \(config.pad)"
            if p.encodeMode == "copy"  { reproducCmd += " --fast" }
            if p.encodeMode == "exact" { reproducCmd += " --exact" }
            if config.thumbnails  { reproducCmd += " --thumbnails" }
            if config.embedSource { reproducCmd += " --embed-source" }

            let engagement: GatherManifestEngagement?
            if hit.viewCount != nil || hit.likeCount != nil || hit.commentCount != nil {
                engagement = GatherManifestEngagement(
                    viewCount:    hit.viewCount,
                    likeCount:    hit.likeCount,
                    commentCount: hit.commentCount
                )
            } else {
                engagement = nil
            }

            let chapter: GatherManifestChapter? = hit.chapterIndex.flatMap { idx in
                guard idx >= 0, idx < hit.chapters.count else { return nil }
                return GatherManifestChapter(title: hit.chapters[idx].title, index: idx)
            }

            let indexStr = GatherPathNaming.paddedClipIndex(p.plan.index, total: p.plan.total)
            manifestClips.append(GatherManifestClip(
                id:                   indexStr,
                videoId:              hit.videoId,
                sourceUrl:            hit.videoId,
                title:                hit.title,
                uploader:             hit.uploader,
                mp4Path:              "./\(mp4Filename)",
                srtPath:              srtFilename.map { "./\($0)" },
                transcriptSource:     transcriptSource,
                logicalStartSeconds:  rc.resolvedStartSeconds,
                logicalEndSeconds:    rc.resolvedEndSeconds,
                padSeconds:           config.pad,
                paddedStartSeconds:   paddedStart,
                paddedEndSeconds:     paddedEnd,
                engagement:           engagement,
                chapter:              chapter,
                reproduceCommand:     reproducCmd,
                srtCuesTrimmed:       false,
                thumbnailPath:        thumbFilename.map { "./\($0)" },
                embedSourceApplied:   p.embedSourceApplied,
                embedSourceNote:      nil,
                encodeMode:           p.encodeMode
            ))
        }

        let manifestPath = (outputDir as NSString).appendingPathComponent("manifest.json")
        do {
            try GatherSidecarWriter.write(
                clips:              manifestClips,
                query:              config.query,
                padSeconds:         config.pad,
                outputDir:          outputDir,
                thumbnailsEnabled:  config.thumbnails,
                embedSourceEnabled: config.embedSource,
                encodeMode:         encodeMode
            )
        } catch {
            progress?("⚠ Could not write manifest/clips.md: \(error.localizedDescription)")
            return nil
        }

        if config.pad > 0 {
            let clampNote = padClampedCount > 0
                ? " (start clamped at 0 on \(padClampedCount) clip(s))"
                : ""
            progress?("Pad: \(String(format: "%g", config.pad)) s handles applied for NLE crossfades\(clampNote).")
        }

        return manifestPath
    }

    // MARK: - Plan builder

    private static func buildClipPlans(
        resolved:  [ResolvedClip],
        outputDir: String,
        config:    GatherConfig
    ) -> [GatherClipPlan] {
        let total       = resolved.count
        let doEmbed     = config.embedSource
        let doThumbnail = config.thumbnails

        return resolved.enumerated().map { (i, rc) in
            let index         = i + 1
            let indexStr      = GatherPathNaming.paddedClipIndex(index, total: total)
            let uploaderToken = GatherPathNaming.uploaderToken(rc.hit.uploader)
            let timeTag       = TimeParser.formatCompact(rc.resolvedStartSeconds)
            let snippet       = GatherPathNaming.filenameSnippet(from: rc.hit.text)
            let filename      = "\(indexStr)_\(uploaderToken)_\(timeTag)_\(snippet).mp4"

            let meta: SourceMetadata? = doEmbed ? SourceMetadata(
                title:   rc.hit.title,
                artist:  rc.hit.uploader,
                comment: "Source: \(rc.hit.videoId) | Gathered by vvx"
            ) : nil

            return GatherClipPlan(
                resolved:         rc,
                outputPath:       (outputDir as NSString).appendingPathComponent(filename),
                index:            index,
                total:            total,
                sourceMetadata:   meta,
                extractThumbnail: doThumbnail
            )
        }
    }

    // MARK: - Output directory

    private static func resolveOutputDirectory(config: GatherConfig) -> String {
        if let explicit = config.outputDir {
            return (NSString(string: explicit).expandingTildeInPath as NSString).standardizingPath
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp  = formatter.string(from: Date())
        let queryToken = GatherPathNaming.sanitizeFolderQuery(config.query)
        let desktop    = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        return (desktop as NSString).appendingPathComponent("Gather_\(queryToken)_\(timestamp)")
    }

    // MARK: - NDJSON helper

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return "" }
        return line
    }
}
