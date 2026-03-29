import ArgumentParser
import Foundation
import VideoVortexCore

// MARK: - Snap mode

enum SnapMode: String, ExpressibleByArgument, CaseIterable {
    case off
    case block
    case chapter
}

// MARK: - GatherResolvedClip (single source of truth for time math)

/// Resolved clip window computed once per hit, used by dry-run, NDJSON, stderr, and ffmpeg.
private struct GatherResolvedClip: Sendable {
    let hit: SearchHit
    /// Final start/end passed to ffmpeg (and emitted in NDJSON).
    let resolvedStartSeconds: Double
    let resolvedEndSeconds: Double
    /// Actual snap mode applied (may differ from requested if fallback occurred).
    let snapApplied: SnapMode
    /// Original FTS cue bounds — used for stderr delta reporting.
    let cueStartSeconds: Double
    let cueEndSeconds: Double
    /// Optional note for throttled stderr (e.g. chapter title).
    let snapNote: String?

    var plannedDuration: Double { resolvedEndSeconds - resolvedStartSeconds }
}

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
    let matchedText: String
    let method: String
    let sizeBytes: Int64?
    let snapApplied: String
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
    let plannedDurationSeconds: Double
    let matchedText: String
    let snapApplied: String
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
    let resolved: GatherResolvedClip
    let outputPath: String
    let index: Int
    let total: Int
}

private enum GatherWorkerOutcome: Sendable {
    case success(SuccessPayload)
    case failure(FailurePayload)

    struct SuccessPayload: Sendable {
        let plan: GatherClipPlan
        let clipResult: ClipResult
        let sizeBytes: Int64?
        let elapsed: TimeInterval
    }

    struct FailurePayload: Sendable {
        let plan: GatherClipPlan
        let error: VvxError
        let elapsed: TimeInterval
    }
}

// MARK: - Command

/// Phase 3.5 Step 3: search, smart boundaries (--snap, --context-seconds), budget cap, SQL engagement filter.
struct GatherCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gather",
        abstract: "Search your archive and extract matching clips as a batch. (Pro feature)",
        discussion: """
        Searches vortex.db for the query and extracts every matching transcript segment
        as a frame-accurate MP4 clip into an organized output folder.

        Clip window flags:
          --context-seconds N  Adds N seconds before/after each matched cue (default: 1.0,
                               start clamped at 0). Use 0 with --snap off for tight cuts.
          --snap off           Cue + context (default).
          --snap block         Exact cue bounds only; ignores --context-seconds.
          --snap chapter       Full chapter span containing the hit; ignores --context-seconds.
                               Falls back to block if chapter_index is missing (run vvx reindex).

        Examples:
          vvx gather "artificial general intelligence" --limit 10
          vvx gather "AI AND danger" --uploader "Lex Fridman" --context-seconds 2
          vvx gather "Tesla" --min-views 1000000 --min-likes 50000
          vvx gather "AGI" --snap chapter --limit 5
          vvx gather "Tesla" --min-views 1000000 --dry-run
          vvx gather "AGI" --limit 5 --fast -o ~/Desktop/agi-clips
          vvx gather "news" --max-total-duration 600
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

    // MARK: - Extraction flags

    @Flag(name: .long, help: "Plan only: show what would be extracted without calling ffmpeg.")
    var dryRun: Bool = false

    @Option(name: [.customShort("o"), .long], help: "Output directory for extracted clips.")
    var output: String?

    @Flag(name: .long, help: "Fast mode: keyframe seek + stream copy (no re-encode). Instant but ±2-5s drift.")
    var fast: Bool = false

    // MARK: - Run

    mutating func run() async throws {
        // 1 — Entitlement gate.
        try await EntitlementChecker.requirePro(.gather)

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

        // 6 — Resolve windows (GatherResolvedClip) for every hit.
        let snapMode = snap
        let ctxSec   = contextSeconds
        let resolved = resolveWindows(hits: hits, snapMode: snapMode, contextSeconds: ctxSec)

        // 7 — Partition: clippable vs skipped (missing local file).
        var clippable: [GatherResolvedClip] = []
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
                    videoId: rc.hit.videoId,
                    startTime: rc.hit.startTime,
                    endTime: rc.hit.endTime
                ))
            }
        }

        let skipNote = skippedCount > 0 ? " (\(skippedCount) skipped — no local file)" : ""
        stderrLine("Found \(resolved.count) clip(s) matching criteria.\(skipNote)")

        if clippable.isEmpty { return }

        // 8 — Apply budget cap (--max-total-duration).
        let (budgetClippable, budgetSkipped) = applyBudgetCap(clippable)

        for bs in budgetSkipped {
            printNDJSON(GatherBudgetSkipEntry(
                videoId:              bs.hit.videoId,
                startTime:            bs.hit.startTime,
                endTime:              bs.hit.endTime,
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

        // 11 — Dry-run branch.
        if dryRun {
            for plan in plans {
                let rc = plan.resolved
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
                    plannedDurationSeconds: rc.plannedDuration,
                    matchedText:            String(rc.hit.text.prefix(200)),
                    snapApplied:            rc.snapApplied.rawValue
                ))
            }
            stderrLine("Dry run: \(plans.count) clip(s) planned\(skipNote).")
            return
        }

        // 12 — Extraction loop (max 4 concurrent, parent-only printing).
        let displayDir = outputDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        stderrLine("Extracting \(plans.count) clip(s) → \(displayDir)")

        let resolvedFfmpeg = ffmpegURL!
        let useFast = fast
        var succeeded = 0
        var failed = 0
        var completed = 0
        let totalPlans = plans.count

        await withTaskGroup(of: GatherWorkerOutcome.self) { group in
            var active = 0

            for plan in plans {
                if active >= 4 {
                    if let outcome = await group.next() {
                        completed += 1
                        emitOutcome(outcome, completed: completed, total: totalPlans,
                                    succeeded: &succeeded, failed: &failed)
                    }
                    active -= 1
                }

                let captured = plan
                group.addTask {
                    return await Self.extractClip(plan: captured, ffmpegPath: resolvedFfmpeg, fast: useFast)
                }
                active += 1
            }

            for await outcome in group {
                completed += 1
                emitOutcome(outcome, completed: completed, total: totalPlans,
                            succeeded: &succeeded, failed: &failed)
            }
        }

        stderrLine("Done. \(succeeded)/\(totalPlans) clip(s) extracted\(failed > 0 ? ", \(failed) failed" : "").")

        if failed > 0 {
            throw ExitCode(1)
        }
    }

    // MARK: - Window resolution (GatherResolvedClip)

    /// Compute `GatherResolvedClip` for every hit.
    /// Emits throttled stderr lines for chapter snap when bounds meaningfully shift.
    private func resolveWindows(
        hits: [SearchHit],
        snapMode: SnapMode,
        contextSeconds: Double
    ) -> [GatherResolvedClip] {
        var snapNoteCount = 0
        let snapNoteMax = 5

        return hits.compactMap { hit in
            let cueStart = hit.startSeconds
            let cueEnd   = GatherPathNaming.parseSRTTimestampToSeconds(hit.endTime)
                ?? (hit.startSeconds + 10)
            let durationMax = hit.videoDurationSeconds.map { Double($0) } ?? Double.greatestFiniteMagnitude

            switch snapMode {
            case .off:
                let start = max(0, cueStart - contextSeconds)
                let end   = min(durationMax, cueEnd + contextSeconds)
                guard end > start else {
                    stderrLine("⚠ Skipping hit at \(hit.startTime) (invalid resolved window after context).")
                    return nil
                }
                return GatherResolvedClip(
                    hit: hit,
                    resolvedStartSeconds: start,
                    resolvedEndSeconds: end,
                    snapApplied: .off,
                    cueStartSeconds: cueStart,
                    cueEndSeconds: cueEnd,
                    snapNote: nil
                )

            case .block:
                let start = cueStart
                let end   = min(durationMax, cueEnd)
                guard end > start else {
                    stderrLine("⚠ Skipping hit at \(hit.startTime) (zero-width cue block).")
                    return nil
                }
                return GatherResolvedClip(
                    hit: hit,
                    resolvedStartSeconds: start,
                    resolvedEndSeconds: end,
                    snapApplied: .block,
                    cueStartSeconds: cueStart,
                    cueEndSeconds: cueEnd,
                    snapNote: nil
                )

            case .chapter:
                // Resolve chapter index → chapter bounds.
                guard let idx = hit.chapterIndex,
                      !hit.chapters.isEmpty,
                      idx >= 0,
                      idx < hit.chapters.count else {
                    // Fallback: block bounds + stderr warning (throttled).
                    stderrLine("--snap chapter: missing chapter_index for hit at \(hit.startTime) (\(hit.videoId)); using cue bounds (run vvx reindex for chapters).")
                    let start = cueStart
                    let end   = min(durationMax, cueEnd)
                    return GatherResolvedClip(
                        hit: hit,
                        resolvedStartSeconds: start,
                        resolvedEndSeconds: end,
                        snapApplied: .block,
                        cueStartSeconds: cueStart,
                        cueEndSeconds: cueEnd,
                        snapNote: nil
                    )
                }

                let ch    = hit.chapters[idx]
                let start = max(0, ch.startTime)
                let rawEnd: Double
                if let chEnd = ch.endTime {
                    rawEnd = chEnd
                } else if let dur = hit.videoDurationSeconds {
                    rawEnd = Double(dur)
                } else {
                    rawEnd = durationMax
                }
                let end = min(durationMax, rawEnd)

                // Degenerate chapter metadata — fall back to block.
                guard end > start else {
                    stderrLine("--snap chapter: degenerate chapter bounds for \"\(ch.title)\"; using cue bounds.")
                    return GatherResolvedClip(
                        hit: hit,
                        resolvedStartSeconds: cueStart,
                        resolvedEndSeconds: min(durationMax, cueEnd),
                        snapApplied: .block,
                        cueStartSeconds: cueStart,
                        cueEndSeconds: cueEnd,
                        snapNote: nil
                    )
                }

                // Throttled "why" stderr: only when window shifted > 0.1s.
                let shifted = abs(start - cueStart) > 0.1 || abs(end - cueEnd) > 0.1
                let note: String? = shifted ? ch.title : nil
                if shifted && snapNoteCount < snapNoteMax {
                    let startFmt = TimeParser.formatHHMMSS(start)
                    let endFmt   = TimeParser.formatHHMMSS(end)
                    let cueSFmt  = TimeParser.formatHHMMSS(cueStart)
                    let cueEFmt  = TimeParser.formatHHMMSS(cueEnd)
                    stderrLine("Snap: cue \(cueSFmt)–\(cueEFmt) → chapter \"\(ch.title)\" \(startFmt)–\(endFmt)")
                    snapNoteCount += 1
                    if snapNoteCount == snapNoteMax {
                        stderrLine("… and more chapter snap(s) (omitted; same --snap chapter behavior).")
                    }
                }

                return GatherResolvedClip(
                    hit: hit,
                    resolvedStartSeconds: start,
                    resolvedEndSeconds: end,
                    snapApplied: .chapter,
                    cueStartSeconds: cueStart,
                    cueEndSeconds: cueEnd,
                    snapNote: note
                )
            }
        }
    }

    // MARK: - Budget cap

    private func applyBudgetCap(
        _ clippable: [GatherResolvedClip]
    ) -> (include: [GatherResolvedClip], skip: [GatherResolvedClip]) {
        guard let cap = maxTotalDuration else {
            return (clippable, [])
        }
        var accumulated = 0.0
        var include: [GatherResolvedClip] = []
        var skip: [GatherResolvedClip]    = []

        for rc in clippable {
            if skip.isEmpty && accumulated + rc.plannedDuration <= cap {
                accumulated += rc.plannedDuration
                include.append(rc)
            } else {
                skip.append(rc)
            }
        }
        return (include, skip)
    }

    // MARK: - Worker (runs inside TaskGroup child — no stdout/stderr)

    private static func extractClip(
        plan: GatherClipPlan,
        ffmpegPath: URL,
        fast: Bool
    ) async -> GatherWorkerOutcome {
        let wallStart = Date()
        let rc = plan.resolved

        do {
            let result = try await FFmpegRunner.clip(
                ffmpegPath: ffmpegPath,
                inputPath:  rc.hit.videoPath!,
                start:      rc.resolvedStartSeconds,
                end:        rc.resolvedEndSeconds,
                outputPath: plan.outputPath,
                fast:       fast
            )
            let elapsed = Date().timeIntervalSince(wallStart)
            let size = try? FileManager.default.attributesOfItem(
                atPath: result.outputPath
            )[.size] as? Int64
            return .success(.init(plan: plan, clipResult: result, sizeBytes: size, elapsed: elapsed))
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
                plan: plan,
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
        failed: inout Int
    ) {
        switch outcome {
        case .success(let p):
            succeeded += 1
            let startFmt = TimeParser.formatHHMMSS(p.clipResult.startSeconds)
            let endFmt   = TimeParser.formatHHMMSS(p.clipResult.endSeconds)
            let label    = p.plan.resolved.hit.uploader ?? p.plan.resolved.hit.title
            stderrLine("[\(completed)/\(total)] ✓ \(label) — \(startFmt)→\(endFmt) (\(String(format: "%.1f", p.elapsed))s)")

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
                matchedText:          String(p.plan.resolved.hit.text.prefix(200)),
                method:               p.clipResult.method,
                sizeBytes:            p.sizeBytes,
                snapApplied:          p.plan.resolved.snapApplied.rawValue
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
        resolved: [GatherResolvedClip],
        outputDir: String
    ) -> [GatherClipPlan] {
        let total = resolved.count

        return resolved.enumerated().map { (i, rc) in
            let index    = i + 1
            let indexStr = GatherPathNaming.paddedClipIndex(index, total: total)
            let uploaderToken = GatherPathNaming.uploaderToken(rc.hit.uploader)
            let timeTag  = TimeParser.formatCompact(rc.resolvedStartSeconds)
            let snippet  = GatherPathNaming.filenameSnippet(from: rc.hit.text)
            let filename = "\(indexStr)_\(uploaderToken)_\(timeTag)_\(snippet).mp4"

            return GatherClipPlan(
                resolved:   rc,
                outputPath: (outputDir as NSString).appendingPathComponent(filename),
                index:      index,
                total:      total
            )
        }
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
