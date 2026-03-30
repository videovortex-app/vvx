import ArgumentParser
import Foundation
import VideoVortexCore

// MARK: - SnapMode CLI conformance

/// `SnapMode` lives in VideoVortexCore without ArgumentParser dependency.
/// This extension adds the `ExpressibleByArgument` conformance needed for `@Option`.
extension SnapMode: ExpressibleByArgument {}

// MARK: - NDJSON models (CLI layer only)

private struct GatherClipSuccess: Encodable {
    let success = true
    let outputPath: String
    let inputPath: String
    let videoId: String
    let title: String
    let uploader: String?
    let startTime: String
    let endTime: String
    let durationSeconds: Double
    let resolvedStartSeconds: Double
    let resolvedEndSeconds: Double
    let padSeconds: Double
    let paddedStartSeconds: Double
    let paddedEndSeconds: Double
    let plannedSrtPath: String?
    let matchedText: String
    let method: String
    let sizeBytes: Int64?
    let snapApplied: String
    // Step 5 fields
    let thumbnailPath: String?
    let embedSourceApplied: Bool
    let embedSourceNote: String?
    /// Encode mode: `"copy"` (--fast), `"default"`, or `"exact"` (--exact, libx264 CRF 18).
    let encodeMode: String
}

private struct GatherClipFailure: Encodable {
    let success = false
    let error: VvxError
    let videoId: String
    let startTime: String
    let endTime: String
}

private struct GatherDryRunEntry: Encodable {
    let success = true
    let dryRun = true
    let plannedOutputPath: String
    let inputPath: String
    let videoId: String
    let title: String
    let uploader: String?
    let startTime: String
    let endTime: String
    let resolvedStartSeconds: Double
    let resolvedEndSeconds: Double
    let padSeconds: Double
    let paddedStartSeconds: Double
    let paddedEndSeconds: Double
    let plannedDurationSeconds: Double
    let plannedSrtPath: String
    let matchedText: String
    let snapApplied: String
    // Step 5 fields
    let plannedThumbnailPath: String?
    let embedSourcePlanned: Bool
    /// Encode mode that would be used: `"copy"`, `"default"`, or `"exact"`.
    let encodeMode: String
}

private struct GatherEmptySummary: Encodable {
    let success = true
    let totalClips = 0
    let query: String
}

private struct GatherBudgetSkipEntry: Encodable {
    let success = false
    let skipped = true
    let reason = "budget_exceeded"
    let videoId: String
    let startTime: String
    let endTime: String
    let plannedDurationSeconds: Double
}

// MARK: - Internal plan + worker outcome

private struct GatherClipPlan: Sendable {
    let resolved: ResolvedClip
    let outputPath: String
    let index: Int
    let total: Int
    /// Non-nil when `--embed-source` is on; carries title/artist/comment for this clip.
    let sourceMetadata: SourceMetadata?
    /// `true` when `--thumbnails` is on for this run.
    let extractThumbnail: Bool
}

private enum GatherWorkerOutcome: Sendable {
    case success(SuccessPayload)
    case failure(FailurePayload)

    struct SuccessPayload: Sendable {
        let plan: GatherClipPlan
        let clipResult: ClipResult
        let sizeBytes: Int64?
        let elapsed: TimeInterval
        let thumbnailPath: String?
        let embedSourceApplied: Bool
        let encodeMode: String
    }

    struct FailurePayload: Sendable {
        let plan: GatherClipPlan
        let error: VvxError
        let elapsed: TimeInterval
    }
}

// MARK: - Command

/// Phase 3.5 Step 5.5: gather orchestration using shared ClipWindowResolver.
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

        Examples:
          vvx gather "artificial general intelligence" --limit 10
          vvx gather "AI AND danger" --uploader "Lex Fridman" --context-seconds 2
          vvx gather "Tesla" --min-views 1000000 --min-likes 50000
          vvx gather "AGI" --snap chapter --limit 5
          vvx gather "Tesla" --min-views 1000000 --dry-run
          vvx gather "AGI" --limit 5 --fast -o ~/Desktop/agi-clips
          vvx gather "news" --max-total-duration 600
          vvx gather "neuralink" --pad 0      # tight cuts, no handles
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

    // MARK: - Engagement filters (pushed into SQL before LIMIT)

    @Option(name: .long, help: "Only gather clips from videos with at least this many views.")
    var minViews: Int?

    @Option(name: .long, help: "Only gather clips from videos with at least this many likes.")
    var minLikes: Int?

    @Option(name: .long, help: "Only gather clips from videos with at least this many comments.")
    var minComments: Int?

    // MARK: - Boundary flags (Step 3)

    @Option(name: .long, help: "Adds N seconds before/after the matched cue (default: 1.0). Ignored when --snap block or --snap chapter.")
    var contextSeconds: Double = 1.0

    @Option(name: .long, help: "Snap mode: off (cue + context), block (exact cue), chapter (full chapter span). Default: off.")
    var snap: SnapMode = .off

    @Option(name: .long, help: "Hard cap on total resolved clip duration in seconds. Drops lower-relevance clips first.")
    var maxTotalDuration: Double?

    // MARK: - Pad flag (Step 4)

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

    // MARK: - Run

    mutating func run() async throws {
        // 1 — Entitlement gate.
        try await EntitlementChecker.requirePro(.gather)

        // 1b — Mutual exclusion: --fast and --exact are semantically opposite.
        if fast && exact {
            let env = VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "Cannot specify both --fast and --exact.",
                agentAction: "Use --fast for stream copy (quick, approximate handles) or --exact for re-encoded high-quality handles — not both."
            ))
            print(env.jsonString())
            throw ExitCode(VvxExitCode.forErrorCode(.parseError))
        }

        stderrLine("Searching vortex.db for gather candidates…")

        // 2 — Open DB.
        let db: VortexDB
        do {
            db = try VortexDB.open()
        } catch {
            let env = VvxErrorEnvelope(error: VvxError(
                code: .indexCorrupt,
                message: "Could not open vortex.db: \(error.localizedDescription)"
            ))
            print(env.jsonString())
            throw ExitCode(VvxExitCode.forErrorCode(.indexCorrupt))
        }

        // 3 — Resolve ffmpeg early (skip for dry-run).
        let ffmpegURL: URL?
        if !dryRun {
            ffmpegURL = EngineResolver.cliResolver.resolvedFfmpegURL()
            guard ffmpegURL != nil else {
                let env = VvxErrorEnvelope(error: VvxError(
                    code: .ffmpegNotFound,
                    message: "ffmpeg is required for clip extraction."
                ))
                print(env.jsonString())
                throw ExitCode(VvxExitCode.engineNotFound)
            }
        } else {
            ffmpegURL = nil
        }

        // 4 — FTS search with engagement filters in SQL (before LIMIT).
        let hits: [SearchHit]
        do {
            hits = try await db.search(
                query:       query,
                platform:    platform,
                afterDate:   after,
                uploader:    uploader,
                minViews:    minViews,
                minLikes:    minLikes,
                minComments: minComments,
                limit:       limit
            )
        } catch {
            let env = VvxErrorEnvelope(error: VvxError(
                code: .indexEmpty,
                message: "Search failed: \(error.localizedDescription)"
            ))
            print(env.jsonString())
            throw ExitCode(1)
        }

        // 5 — Zero hits.
        if hits.isEmpty {
            stderrLine("No clips matching criteria.")
            printNDJSON(GatherEmptySummary(query: query))
            return
        }

        // 6 — Resolve windows via shared ClipWindowResolver; print any warnings.
        let (resolved, resolveWarnings) = ClipWindowResolver.resolveWindows(
            hits:           hits,
            snapMode:       snap,
            contextSeconds: contextSeconds
        )
        for w in resolveWarnings { stderrLine(w) }

        // 7 — Partition: clippable vs skipped (missing local file).
        var clippable: [ResolvedClip] = []
        var skippedCount = 0

        for rc in resolved {
            if let path = rc.hit.videoPath, FileManager.default.fileExists(atPath: path) {
                clippable.append(rc)
            } else {
                skippedCount += 1
                printNDJSON(GatherClipFailure(
                    error: VvxError(
                        code: .videoUnavailable,
                        message: "Source video not on disk for \(rc.hit.videoId). Download it first.",
                        agentAction: "Run 'vvx fetch \"\(rc.hit.videoId)\" --archive' to download the video, then retry gather."
                    ),
                    videoId:   rc.hit.videoId,
                    startTime: rc.hit.startTime,
                    endTime:   rc.hit.endTime
                ))
            }
        }

        let skipNote = skippedCount > 0 ? " (\(skippedCount) skipped — no local file)" : ""
        stderrLine("Found \(resolved.count) clip(s) matching criteria.\(skipNote)")

        if clippable.isEmpty { return }

        // 8 — Apply budget cap (--max-total-duration).
        let (budgetClippable, budgetSkipped) = ClipWindowResolver.applyBudgetCap(
            clippable,
            maxTotalDuration: maxTotalDuration
        )

        for bs in budgetSkipped {
            printNDJSON(GatherBudgetSkipEntry(
                videoId:                bs.hit.videoId,
                startTime:              bs.hit.startTime,
                endTime:                bs.hit.endTime,
                plannedDurationSeconds: bs.plannedDuration
            ))
        }

        if !budgetSkipped.isEmpty {
            stderrLine("Budget: skipped \(budgetSkipped.count) clip(s) to stay under --max-total-duration (lower-relevance hits dropped first).")
        }

        if budgetClippable.isEmpty { return }

        // 9 — Output directory.
        let outputDir = resolveOutputDirectory()
        if !dryRun {
            try FileManager.default.createDirectory(
                atPath: outputDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        // 10 — Build clip plans.
        let plans = buildClipPlans(resolved: budgetClippable, outputDir: outputDir)

        // 11 — Capture flags locally for use in TaskGroup and closures.
        let padValue       = pad
        let useThumbnails  = thumbnails
        let useEmbedSource = embedSource
        let useExact       = exact
        let runEncodeMode  = fast ? "copy" : (exact ? "exact" : "default")

        // 12 — Dry-run branch.
        if dryRun {
            for plan in plans {
                let rc      = plan.resolved
                let padded  = FFmpegRunner.paddedBounds(
                    logicalStart:  rc.resolvedStartSeconds,
                    logicalEnd:    rc.resolvedEndSeconds,
                    pad:           padValue,
                    videoDuration: rc.hit.videoDurationSeconds.map { Double($0) }
                )
                let srtPlan   = (plan.outputPath as NSString).deletingPathExtension + ".srt"
                let thumbPlan = thumbnails
                    ? ((plan.outputPath as NSString).deletingPathExtension + ".jpg")
                    : nil
                printNDJSON(GatherDryRunEntry(
                    plannedOutputPath:      plan.outputPath,
                    inputPath:              rc.hit.videoPath ?? "",
                    videoId:                rc.hit.videoId,
                    title:                  rc.hit.title,
                    uploader:               rc.hit.uploader,
                    startTime:              TimeParser.formatHHMMSS(rc.resolvedStartSeconds),
                    endTime:                TimeParser.formatHHMMSS(rc.resolvedEndSeconds),
                    resolvedStartSeconds:   rc.resolvedStartSeconds,
                    resolvedEndSeconds:     rc.resolvedEndSeconds,
                    padSeconds:             padValue,
                    paddedStartSeconds:     padded.start,
                    paddedEndSeconds:       padded.end,
                    plannedDurationSeconds: padded.end - padded.start,
                    plannedSrtPath:         srtPlan,
                    matchedText:            String(rc.hit.text.prefix(200)),
                    snapApplied:            rc.snapApplied.rawValue,
                    plannedThumbnailPath:   thumbPlan,
                    embedSourcePlanned:     embedSource,
                    encodeMode:             runEncodeMode
                ))
            }
            stderrLine("Dry run: \(plans.count) clip(s) planned\(skipNote).")
            return
        }

        // 13 — Extraction loop (max 4 concurrent, parent-only printing).
        let displayDir = outputDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        stderrLine("Extracting \(plans.count) clip(s) → \(displayDir)")

        let resolvedFfmpeg = ffmpegURL!
        let useFast        = fast
        let useExactMode   = useExact
        var succeeded      = 0
        var failed         = 0
        var completed      = 0
        let totalPlans     = plans.count
        var successPayloads: [GatherWorkerOutcome.SuccessPayload] = []

        await withTaskGroup(of: GatherWorkerOutcome.self) { group in
            var active = 0

            for plan in plans {
                if active >= 4 {
                    if let outcome = await group.next() {
                        completed += 1
                        emitOutcome(outcome, completed: completed, total: totalPlans,
                                    succeeded: &succeeded, failed: &failed,
                                    pad: padValue)
                        if case .success(let p) = outcome { successPayloads.append(p) }
                    }
                    active -= 1
                }

                let captured = plan
                group.addTask {
                    return await Self.extractClip(
                        plan:       captured,
                        ffmpegPath: resolvedFfmpeg,
                        fast:       useFast,
                        exact:      useExactMode,
                        pad:        padValue,
                        thumbnails: useThumbnails
                    )
                }
                active += 1
            }

            for await outcome in group {
                completed += 1
                emitOutcome(outcome, completed: completed, total: totalPlans,
                            succeeded: &succeeded, failed: &failed,
                            pad: padValue)
                if case .success(let p) = outcome { successPayloads.append(p) }
            }
        }

        stderrLine("Done. \(succeeded)/\(totalPlans) clip(s) extracted\(failed > 0 ? ", \(failed) failed" : "").")

        // 14 — Write sidecars for all successful clips.
        if !successPayloads.isEmpty {
            successPayloads.sort { $0.plan.index < $1.plan.index }
            await writeSidecars(
                successPayloads: successPayloads,
                db:              db,
                outputDir:       outputDir,
                padValue:        padValue,
                useThumbnails:   useThumbnails,
                useEmbedSource:  useEmbedSource,
                encodeMode:      runEncodeMode
            )
        }

        // 15 — Thumbnail summary.
        if useThumbnails && !successPayloads.isEmpty {
            let written = successPayloads.filter { $0.thumbnailPath != nil }.count
            let failed2 = successPayloads.count - written
            if written > 0 { stderrLine("Thumbnails: wrote \(written) image(s).") }
            if failed2 > 0 { stderrLine("⚠ Thumbnails: \(failed2) image(s) could not be extracted.") }
        }

        // 16 — Open output folder if requested (best-effort, non-fatal).
        if openOutput && succeeded > 0 {
            revealOutputDirectory(outputDir)
        }

        if failed > 0 {
            throw ExitCode(1)
        }
    }

    // MARK: - Sidecar writing (post-extraction, sequential)

    private func writeSidecars(
        successPayloads: [GatherWorkerOutcome.SuccessPayload],
        db: VortexDB,
        outputDir: String,
        padValue: Double,
        useThumbnails: Bool,
        useEmbedSource: Bool,
        encodeMode: String
    ) async {
        var manifestClips: [GatherManifestClip] = []
        var padClampedCount = 0

        for p in successPayloads {
            let rc          = p.plan.resolved
            let hit         = rc.hit
            let paddedStart = p.clipResult.startSeconds
            let paddedEnd   = p.clipResult.endSeconds

            // Count how many clips had their start clamped by pad (would have gone < 0).
            if rc.resolvedStartSeconds - padValue < -0.001 { padClampedCount += 1 }

            // Fetch transcript blocks for this video and write re-timed SRT.
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
                    stderrLine("⚠ Could not write SRT for \(hit.videoId): \(error.localizedDescription)")
                    srtPathAbs = nil
                }
                transcriptSource = "local"
            } else {
                // retimed() returned nil — no blocks overlap the padded window.
                srtPathAbs       = nil
                transcriptSource = "local"
            }

            // Relative paths for manifest (folder can be zipped/moved).
            let mp4Filename   = URL(fileURLWithPath: p.plan.outputPath).lastPathComponent
            let srtFilename   = srtPathAbs.map { URL(fileURLWithPath: $0).lastPathComponent }
            let thumbFilename = p.thumbnailPath.map { URL(fileURLWithPath: $0).lastPathComponent }

            // Shell-safe reproduce command (copy-paste ready, includes Step 5 flags when used).
            let srcPath     = hit.videoPath ?? "UNKNOWN_PATH"
            var reproducCmd = "vvx clip \"\(srcPath)\" --start \(rc.resolvedStartSeconds) --end \(rc.resolvedEndSeconds) --pad \(padValue)"
            if p.encodeMode == "copy"  { reproducCmd += " --fast" }
            if p.encodeMode == "exact" { reproducCmd += " --exact" }
            if useThumbnails  { reproducCmd += " --thumbnails" }
            if useEmbedSource { reproducCmd += " --embed-source" }

            // Engagement snapshot — omit object when all fields nil.
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

            // Chapter info (if present on this hit).
            let chapter: GatherManifestChapter? = hit.chapterIndex.flatMap { idx in
                guard idx >= 0, idx < hit.chapters.count else { return nil }
                return GatherManifestChapter(title: hit.chapters[idx].title, index: idx)
            }

            let indexStr = GatherPathNaming.paddedClipIndex(p.plan.index, total: p.plan.total)
            manifestClips.append(GatherManifestClip(
                id:                   indexStr,
                videoId:              hit.videoId,
                sourceUrl:            hit.videoId,   // videos.id IS the canonical URL
                title:                hit.title,
                uploader:             hit.uploader,
                mp4Path:              "./\(mp4Filename)",
                srtPath:              srtFilename.map { "./\($0)" },
                transcriptSource:     transcriptSource,
                logicalStartSeconds:  rc.resolvedStartSeconds,
                logicalEndSeconds:    rc.resolvedEndSeconds,
                padSeconds:           padValue,
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

        // Write manifest.json + clips.md.
        do {
            try GatherSidecarWriter.write(
                clips:              manifestClips,
                query:              query,
                padSeconds:         padValue,
                outputDir:          outputDir,
                thumbnailsEnabled:  useThumbnails,
                embedSourceEnabled: useEmbedSource,
                encodeMode:         encodeMode
            )
        } catch {
            stderrLine("⚠ Could not write manifest/clips.md: \(error.localizedDescription)")
        }

        // Single-line stderr pad summary.
        if padValue > 0 {
            let clampNote = padClampedCount > 0
                ? " (start clamped at 0 on \(padClampedCount) clip(s))"
                : ""
            stderrLine("Pad: \(String(format: "%g", padValue)) s handles applied for NLE crossfades\(clampNote).")
        }
    }

    // MARK: - Worker (runs inside TaskGroup child — no stdout/stderr)

    private static func extractClip(
        plan: GatherClipPlan,
        ffmpegPath: URL,
        fast: Bool,
        exact: Bool,
        pad: Double,
        thumbnails: Bool
    ) async -> GatherWorkerOutcome {
        let wallStart = Date()
        let rc = plan.resolved
        let clipEncodeMode = fast ? "copy" : (exact ? "exact" : "default")

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

            // Thumbnail at L0 (logical start from source — shows the matched thought, not pad handle).
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
            let size = try? FileManager.default.attributesOfItem(
                atPath: result.outputPath
            )[.size] as? Int64
            return .success(.init(
                plan:               plan,
                clipResult:         result,
                sizeBytes:          size,
                elapsed:            elapsed,
                thumbnailPath:      thumbPath,
                embedSourceApplied: plan.sourceMetadata != nil,
                encodeMode:         clipEncodeMode
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
                plan:  plan,
                error: VvxError(code: .clipFailed,
                                message: "Clip extraction failed: \(error.localizedDescription)"),
                elapsed: elapsed
            ))
        }
    }

    // MARK: - Outcome processing (parent-side, sequential)

    private func emitOutcome(
        _ outcome: GatherWorkerOutcome,
        completed: Int,
        total: Int,
        succeeded: inout Int,
        failed: inout Int,
        pad: Double
    ) {
        switch outcome {
        case .success(let p):
            succeeded += 1
            let startFmt = TimeParser.formatHHMMSS(p.clipResult.startSeconds)
            let endFmt   = TimeParser.formatHHMMSS(p.clipResult.endSeconds)
            let label    = p.plan.resolved.hit.uploader ?? p.plan.resolved.hit.title
            stderrLine("[\(completed)/\(total)] ✓ \(label) — \(startFmt)→\(endFmt) (\(String(format: "%.1f", p.elapsed))s)")

            let srtPlan = (p.plan.outputPath as NSString).deletingPathExtension + ".srt"
            printNDJSON(GatherClipSuccess(
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
                encodeMode:           p.encodeMode
            ))

        case .failure(let p):
            failed += 1
            let startFmt = TimeParser.formatHHMMSS(p.plan.resolved.resolvedStartSeconds)
            let label    = p.plan.resolved.hit.uploader ?? p.plan.resolved.hit.title
            stderrLine("[\(completed)/\(total)] ✗ \(label) — \(startFmt) (\(p.error.message))")

            printNDJSON(GatherClipFailure(
                error:     p.error,
                videoId:   p.plan.resolved.hit.videoId,
                startTime: p.plan.resolved.hit.startTime,
                endTime:   p.plan.resolved.hit.endTime
            ))
        }
    }

    // MARK: - Plan builder

    private func buildClipPlans(
        resolved: [ResolvedClip],
        outputDir: String
    ) -> [GatherClipPlan] {
        let total       = resolved.count
        let doEmbed     = embedSource
        let doThumbnail = thumbnails

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

    // MARK: - Output directory

    private func resolveOutputDirectory() -> String {
        if let explicit = output {
            return (NSString(string: explicit).expandingTildeInPath as NSString).standardizingPath
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp   = formatter.string(from: Date())
        let queryToken  = GatherPathNaming.sanitizeFolderQuery(query)
        let desktop     = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        return (desktop as NSString).appendingPathComponent("Gather_\(queryToken)_\(timestamp)")
    }
}

// MARK: - Free helpers

private func printNDJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

private func stderrLine(_ message: String) {
    Foundation.fputs(message + "\n", stderr)
}
