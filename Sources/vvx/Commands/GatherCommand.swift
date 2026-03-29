import ArgumentParser
import Foundation
import VideoVortexCore

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
    let matchedText: String
    let method: String
    let sizeBytes: Int64?
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
    let matchedText: String
}

private struct GatherEmptySummary: Encodable {
    let success = true
    let totalClips = 0
    let query: String
}

// MARK: - Internal plan + worker outcome

private struct GatherClipPlan: Sendable {
    let hit: SearchHit
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

/// Phase 3.5 Step 2 full MVP: search, engagement filter, optional dry-run, NDJSON + ffmpeg extraction.
struct GatherCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gather",
        abstract: "Search your archive and extract matching clips as a batch. (Pro feature)",
        discussion: """
        Searches vortex.db for the query and extracts every matching transcript segment
        as a frame-accurate MP4 clip into an organized output folder — without you
        having to script the search-to-clip loop yourself.

        Examples:
          vvx gather "artificial general intelligence" --limit 10
          vvx gather "AI AND danger" --uploader "Lex Fridman"
          vvx gather "Tesla" --min-views 1000000 --min-likes 50000
          vvx gather "Tesla" --min-views 1000000 --dry-run
          vvx gather "AGI" --limit 5 --fast -o ~/Desktop/agi-clips
        """
    )

    // MARK: - Search flags (mirror SearchCommand)

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

    // MARK: - Extraction flags (Step 2)

    @Flag(name: .long, help: "Plan only: show what would be extracted without calling ffmpeg.")
    var dryRun: Bool = false

    @Option(name: [.customShort("o"), .long], help: "Output directory for extracted clips.")
    var output: String?

    @Flag(name: .long, help: "Fast mode: keyframe seek + stream copy (no re-encode). Instant but ±2-5s drift.")
    var fast: Bool = false

    // MARK: - Run

    mutating func run() async throws {
        // B.1 — Entitlement gate (first statement).
        try await EntitlementChecker.requirePro(.gather)

        stderrLine("Searching vortex.db for gather candidates…")

        // B.2 — Open DB.
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

        // B.3 — Resolve ffmpeg early (skip for dry-run).
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

        // B.4 — FTS search + engagement filter.
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
            let env = VvxErrorEnvelope(error: VvxError(
                code: .indexEmpty,
                message: "Search failed: \(error.localizedDescription)"
            ))
            print(env.jsonString())
            throw ExitCode(1)
        }

        // Post-FTS engagement filter (Step 3 may push into SQL JOIN).
        let filteredHits: [SearchHit]
        if minViews != nil || minLikes != nil || minComments != nil {
            filteredHits = try await applyEngagementFilter(hits: hits, db: db)
        } else {
            filteredHits = hits
        }

        // B.5 — Zero hits.
        if filteredHits.isEmpty {
            stderrLine("No clips matching criteria.")
            printNDJSON(GatherEmptySummary(query: query))
            return
        }

        // B.6 — Partition into clippable vs skipped.
        var clippableHits: [SearchHit] = []
        var skippedCount = 0

        for hit in filteredHits {
            if let path = hit.videoPath, FileManager.default.fileExists(atPath: path) {
                clippableHits.append(hit)
            } else {
                skippedCount += 1
                let failure = GatherClipFailure(
                    error: VvxError(
                        code: .videoUnavailable,
                        message: "Source video not on disk for \(hit.videoId). Download it first.",
                        agentAction: "Run 'vvx fetch \"\(hit.videoId)\" --archive' to download the video, then retry gather."
                    ),
                    videoId: hit.videoId,
                    startTime: hit.startTime,
                    endTime: hit.endTime
                )
                printNDJSON(failure)
            }
        }

        let skipNote = skippedCount > 0 ? " (\(skippedCount) skipped — no local file)" : ""
        stderrLine("Found \(filteredHits.count) clip(s) matching criteria.\(skipNote)")

        if clippableHits.isEmpty {
            return
        }

        // B.7 — Output directory.
        let outputDir = resolveOutputDirectory()
        if !dryRun {
            try FileManager.default.createDirectory(
                atPath: outputDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        // B.8 — Build clip plans.
        let plans = buildClipPlans(hits: clippableHits, outputDir: outputDir)

        // D — Dry-run branch.
        if dryRun {
            for plan in plans {
                let entry = GatherDryRunEntry(
                    plannedOutputPath: plan.outputPath,
                    inputPath: plan.hit.videoPath ?? "",
                    videoId: plan.hit.videoId,
                    title: plan.hit.title,
                    uploader: plan.hit.uploader,
                    startTime: plan.hit.startTime,
                    endTime: plan.hit.endTime,
                    matchedText: String(plan.hit.text.prefix(200))
                )
                printNDJSON(entry)
            }
            stderrLine("Dry run: \(plans.count) clip(s) planned\(skipNote).")
            return
        }

        // E — Extraction loop (max 4 concurrent, parent-only printing).
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
                    return await Self.extractClip(
                        plan: captured, ffmpegPath: resolvedFfmpeg, fast: useFast
                    )
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

    // MARK: - Worker (runs inside TaskGroup child — no stdout/stderr)

    private static func extractClip(
        plan: GatherClipPlan, ffmpegPath: URL, fast: Bool
    ) async -> GatherWorkerOutcome {
        let wallStart = Date()
        let endSec = GatherPathNaming.parseSRTTimestampToSeconds(plan.hit.endTime)
            ?? plan.hit.startSeconds + 10

        do {
            let result = try await FFmpegRunner.clip(
                ffmpegPath: ffmpegPath,
                inputPath:  plan.hit.videoPath!,
                start:      plan.hit.startSeconds,
                end:        endSec,
                outputPath: plan.outputPath,
                fast:       fast
            )
            let elapsed = Date().timeIntervalSince(wallStart)
            let size = try? FileManager.default.attributesOfItem(
                atPath: result.outputPath
            )[.size] as? Int64
            return .success(.init(
                plan: plan, clipResult: result, sizeBytes: size, elapsed: elapsed
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
                    agentAction: "Run 'vvx fetch \"\(plan.hit.videoId)\" --archive' to download the video, then retry gather."
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
            let label    = p.plan.hit.uploader ?? p.plan.hit.title
            stderrLine("[\(completed)/\(total)] ✓ \(label) — \(startFmt)→\(endFmt) (\(String(format: "%.1f", p.elapsed))s)")

            printNDJSON(GatherClipSuccess(
                outputPath:      p.clipResult.outputPath,
                inputPath:       p.clipResult.inputPath,
                videoId:         p.plan.hit.videoId,
                title:           p.plan.hit.title,
                uploader:        p.plan.hit.uploader,
                startTime:       TimeParser.formatHHMMSS(p.clipResult.startSeconds),
                endTime:         TimeParser.formatHHMMSS(p.clipResult.endSeconds),
                durationSeconds: p.clipResult.durationSeconds,
                matchedText:     String(p.plan.hit.text.prefix(200)),
                method:          p.clipResult.method,
                sizeBytes:       p.sizeBytes
            ))

        case .failure(let p):
            failed += 1
            let startFmt = TimeParser.formatHHMMSS(p.plan.hit.startSeconds)
            let label    = p.plan.hit.uploader ?? p.plan.hit.title
            stderrLine("[\(completed)/\(total)] ✗ \(label) — \(startFmt) (\(p.error.message))")

            printNDJSON(GatherClipFailure(
                error:     p.error,
                videoId:   p.plan.hit.videoId,
                startTime: p.plan.hit.startTime,
                endTime:   p.plan.hit.endTime
            ))
        }
    }

    // MARK: - Plan builder

    private func buildClipPlans(hits: [SearchHit], outputDir: String) -> [GatherClipPlan] {
        let total = hits.count

        return hits.enumerated().map { (i, hit) in
            let index = i + 1
            let indexStr = GatherPathNaming.paddedClipIndex(index, total: total)

            let uploaderToken = GatherPathNaming.uploaderToken(hit.uploader)

            let timeTag = TimeParser.formatCompact(hit.startSeconds)
            let snippet = GatherPathNaming.filenameSnippet(from: hit.text)
            let filename = "\(indexStr)_\(uploaderToken)_\(timeTag)_\(snippet).mp4"

            return GatherClipPlan(
                hit: hit,
                outputPath: (outputDir as NSString).appendingPathComponent(filename),
                index: index,
                total: total
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
        let timestamp = formatter.string(from: Date())
        let queryToken = GatherPathNaming.sanitizeFolderQuery(query)

        let desktop = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        return (desktop as NSString).appendingPathComponent("Gather_\(queryToken)_\(timestamp)")
    }

    // MARK: - Engagement post-filter

    /// Loads video rows from vortex.db and drops hits whose source video falls
    /// below any specified engagement threshold.
    ///
    /// Nullable engagement columns: when the platform did not provide a value,
    /// the filter for that field is skipped (conservative: we don't exclude
    /// what we can't measure).
    private func applyEngagementFilter(hits: [SearchHit], db: VortexDB) async throws -> [SearchHit] {
        let uniqueVideoIds = Set(hits.map { $0.videoId })

        let allVideos = try await db.allVideos()
        let recordMap = Dictionary(
            uniqueKeysWithValues: allVideos
                .filter { uniqueVideoIds.contains($0.id) }
                .map { ($0.id, $0) }
        )

        return hits.filter { hit in
            guard let record = recordMap[hit.videoId] else { return true }
            if let threshold = minViews, let actual = record.viewCount, actual < threshold { return false }
            if let threshold = minLikes, let actual = record.likeCount, actual < threshold { return false }
            if let threshold = minComments, let actual = record.commentCount, actual < threshold { return false }
            return true
        }
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
