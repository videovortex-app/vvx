import ArgumentParser
import Foundation
import VideoVortexCore

// MARK: - SyncCommand

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract:    "Sync a playlist or channel into your local archive (metadata, transcripts; use --archive for media in the vault).",
        discussion:  """
        Resolves all video URLs from a channel, playlist, or collection using
        yt-dlp --flat-playlist, then senses (or archives) each one concurrently
        with up to 3 workers. Every successful completion is indexed into vortex.db
        automatically. NDJSON (one object per video) streams to stdout as each
        video completes; human-readable progress streams to stderr.

        Pass `--archive` to save MP4 + sidecars to the vault — same meaning as
        `vvx fetch --archive` for a single video.

        A shared 429 coordinator ensures all workers respect the same backoff
        window — no worker will hammer the platform while another is sleeping.

        Use `--incremental` to skip videos already in the local vault. Combine with
        `--limit N` to collect N *new* videos (yt-dlp streams beyond N if needed).
        Use `--match-title` and `--after-date` to let yt-dlp pre-filter the playlist.

        Examples:
          vvx sync "https://youtube.com/@channel" --limit 20
          vvx sync "https://youtube.com/playlist?list=..." --limit 50 --archive
          vvx sync "@lexfridman" --limit 10 --metadata-only
          vvx sync "https://youtube.com/@channel" --limit 5 --no-auto-update
        """
    )

    // MARK: - Arguments

    @Argument(help: "YouTube channel (@handle), playlist URL, or collection URL to sync into your local archive.")
    var url: String

    @Option(name: .long, help: "Maximum number of videos to process from the playlist.")
    var limit: Int?

    @Flag(name: .long, help: "Archive mode: download MP4 + SRT + .info.json instead of sense-only.")
    var archive: Bool = false

    @Flag(name: .long, help: "Request all English subtitle variants (en.*). Default is en,en-orig; safer against YouTube 429s.")
    var allSubs: Bool = false

    @Flag(name: .long, help: "Return metadata and token counts only — omits transcriptBlocks from NDJSON. estimatedTokens and chapter token counts are still populated for planning.")
    var metadataOnly: Bool = false

    @Flag(name: .long, help: "Deprecated no-op. yt-dlp is no longer auto-updated by vvx.")
    var noAutoUpdate: Bool = false

    @Flag(name: .long, help: "Skip videos already in the local vault (sensed_at IS NOT NULL).")
    var incremental: Bool = false

    @Flag(name: .long, help: "Force re-sync of videos even if --incremental is passed.")
    var force: Bool = false

    @Option(name: .long, help: "Only sync videos whose title matches this regex pattern (passed to yt-dlp --match-title).")
    var matchTitle: String?

    @Option(name: .long, help: "Only sync videos on or after this date. Accepts YYYYMMDD, '7d', 'today', etc. (parsed natively by yt-dlp).")
    var afterDate: String?

    // MARK: - Entry point

    mutating func run() async throws {
        let resolver = EngineResolver.cliResolver
        guard let ytDlpURL = resolver.resolvedYtDlpURL() else {
            CLIOutputFormatter.engineNotFound()
            throw ExitCode(VvxExitCode.engineNotFound)
        }

        let config = VvxConfig.load()
        let outDir = config.resolvedTranscriptDirectory()

        // Banner on stderr — stdout is reserved for NDJSON.
        let limitLabel = limit.map { " --limit \($0)" } ?? ""
        let incrementalLabel = incremental ? " --incremental" : ""
        fputs("Syncing \(url)\(limitLabel)\(incrementalLabel)…\n", stderr)

        // Open a single DB connection for the hot-path duplicate check.
        // Workers open their own connections for indexing (WAL-safe concurrent writes).
        // Fail-open: if the DB is unavailable the incremental check is simply skipped.
        let dupCheckDB: VortexDB? = incremental ? (try? VortexDB.open()) : nil

        // Shared 429 gate: all TaskGroup children await this before invoking yt-dlp.
        let coordinator = RateLimitCoordinator()
        let succeeded   = SyncCounter()
        let failed      = SyncCounter()
        let indexed     = SyncCounter()

        // Incremental counters — mutated only in the sequential for-await loop (safe).
        var newVideosEnqueued = 0
        var skippedCount      = 0

        // When --incremental is active, do NOT cap yt-dlp via --playlist-items.
        // The Swift loop below breaks once `newVideosEnqueued == limit`, ensuring we
        // collect `limit` *new* videos even if many playlist entries are duplicates.
        let resolverLimit = incremental ? nil : limit

        await withTaskGroup(of: Void.self) { group in
            var active = 0

            do {
                streamLoop: for try await videoURL in PlaylistResolver.resolve(
                    url:        url,
                    limit:      resolverLimit,
                    matchTitle: matchTitle,
                    afterDate:  afterDate,
                    ytDlpPath:  ytDlpURL
                ) {
                    // Incremental duplicate check — runs before any yt-dlp work is scheduled.
                    if incremental && !force {
                        let isDuplicate = (try? await dupCheckDB?.containsSensedVideo(id: videoURL)) ?? false
                        if isDuplicate {
                            skippedCount += 1
                            NDJSONStreamer.syncSkippedLine(url: videoURL)
                            NDJSONStreamer.writeSyncSkipped(url: videoURL)
                            continue streamLoop
                        }
                    }

                    // Drain one completed slot before adding another when at capacity.
                    if active >= 3 {
                        await group.next()
                        active -= 1
                    }

                    newVideosEnqueued += 1
                    let slot = newVideosEnqueued

                    // Capture all values the child task needs — no `self` capture
                    // inside `addTask` avoids Sendable conformance warnings.
                    let captureURL        = videoURL
                    let captureOutDir     = outDir
                    let captureYtDlp      = ytDlpURL
                    let captureResolver   = resolver
                    let captureAllSubs    = allSubs
                    let captureNoUpdate   = noAutoUpdate
                    let captureArchive    = archive
                    let captureMetaOnly   = metadataOnly
                    let captureSlotTotal  = limit

                    group.addTask {
                        await runSyncWorker(
                            videoURL:     captureURL,
                            slot:         slot,
                            slotTotal:    captureSlotTotal,
                            outDir:       captureOutDir,
                            ytDlpURL:     captureYtDlp,
                            resolver:     captureResolver,
                            allSubs:      captureAllSubs,
                            noAutoUpdate: captureNoUpdate,
                            archive:      captureArchive,
                            metadataOnly: captureMetaOnly,
                            coordinator:  coordinator,
                            succeeded:    succeeded,
                            failed:       failed,
                            indexed:      indexed
                        )
                    }

                    active += 1

                    // Early stop: we have enqueued the requested number of *new* videos.
                    if let limit, newVideosEnqueued == limit {
                        break streamLoop
                    }
                }
            } catch {
                // PlaylistResolver failed to resolve the collection (bad URL, network,
                // permission error, etc.). Report to stderr; NDJSON stdout stays clean.
                fputs("vvx sync: playlist resolution failed — \(error.localizedDescription)\n", stderr)
            }

            // Drain all remaining in-flight workers before printing the summary.
            for await _ in group {}
        }

        let s = await succeeded.value
        let f = await failed.value
        let i = await indexed.value
        NDJSONStreamer.syncDone(succeeded: s, failed: f, skipped: skippedCount, indexed: i)
    }
}

// MARK: - Worker (free function — avoids implicit self capture in addTask)

/// Runs a single sync job (sense or archive) for one resolved video URL.
///
/// Before starting any yt-dlp work, suspends until the shared `RateLimitCoordinator`
/// clears. On a `.rateLimited` failure, registers the backoff so all sibling workers
/// respect the same global pause window.
private func runSyncWorker(
    videoURL:     String,
    slot:         Int,
    slotTotal:    Int?,
    outDir:       URL,
    ytDlpURL:     URL,
    resolver:     EngineResolver,
    allSubs:      Bool,
    noAutoUpdate: Bool,
    archive:      Bool,
    metadataOnly: Bool,
    coordinator:  RateLimitCoordinator,
    succeeded:    SyncCounter,
    failed:       SyncCounter,
    indexed:      SyncCounter
) async {
    // Global 429 gate: suspend until the shared backoff window clears.
    await coordinator.waitUntilSafeToProceed()

    if archive {
        await runArchiveWorker(
            videoURL:     videoURL,
            slot:         slot,
            slotTotal:    slotTotal,
            ytDlpURL:     ytDlpURL,
            resolver:     resolver,
            allSubs:      allSubs,
            noAutoUpdate: noAutoUpdate,
            coordinator:  coordinator,
            succeeded:    succeeded,
            failed:       failed,
            indexed:      indexed
        )
    } else {
        await runSenseWorker(
            videoURL:     videoURL,
            slot:         slot,
            slotTotal:    slotTotal,
            outDir:       outDir,
            ytDlpURL:     ytDlpURL,
            allSubs:      allSubs,
            noAutoUpdate: noAutoUpdate,
            metadataOnly: metadataOnly,
            coordinator:  coordinator,
            succeeded:    succeeded,
            failed:       failed,
            indexed:      indexed
        )
    }
}

// MARK: - Sense worker

private func runSenseWorker(
    videoURL:     String,
    slot:         Int,
    slotTotal:    Int?,
    outDir:       URL,
    ytDlpURL:     URL,
    allSubs:      Bool,
    noAutoUpdate: Bool,
    metadataOnly: Bool,
    coordinator:  RateLimitCoordinator,
    succeeded:    SyncCounter,
    failed:       SyncCounter,
    indexed:      SyncCounter
) async {
    let senseConfig = SenseConfig(
        url:                    videoURL,
        outputDirectory:        outDir,
        ytDlpPath:              ytDlpURL,
        allSubtitleLanguages:   allSubs,
        requestHumanLikePacing: true   // multiple concurrent workers → human-like pacing
    )
    let senser = VideoSenser()

    for await event in senser.sense(config: senseConfig) {
        switch event {

        case .completed(let result):
            NDJSONStreamer.syncProgressLine(
                index: slot, total: slotTotal,
                title: result.title, success: true
            )
            // Emit SenseResult v3 NDJSON to stdout immediately (streaming).
            let output = metadataOnly ? result.withEmptyBlocks() : result
            NDJSONStreamer.writeSenseResult(output)
            await succeeded.increment()

            // Index into vortex.db — fresh connection per worker (WAL-safe).
            let wasIndexed = await indexSenseResult(result, videoURL: videoURL)
            if wasIndexed { await indexed.increment() }

        case .failed(let error):
            NDJSONStreamer.syncProgressLine(
                index: slot, total: slotTotal,
                title: nil, success: false
            )
            NDJSONStreamer.writeError(error)
            await failed.increment()

            // Register global backoff so all sibling workers pause before their
            // next yt-dlp invocation. `VideoSenser` already exhausted its own
            // per-process retries at this point.
            if error.code == .rateLimited {
                await coordinator.registerRateLimit()
            }

        default:
            break
        }
    }
}

// MARK: - Archive worker

private func runArchiveWorker(
    videoURL:     String,
    slot:         Int,
    slotTotal:    Int?,
    ytDlpURL:     URL,
    resolver:     EngineResolver,
    allSubs:      Bool,
    noAutoUpdate: Bool,
    coordinator:  RateLimitCoordinator,
    succeeded:    SyncCounter,
    failed:       SyncCounter,
    indexed:      SyncCounter
) async {
    // Resolve archive output directory.
    guard let archiveRoot = MediaStoragePaths.archiveRoot() else {
        fputs("vvx sync: could not resolve archive directory for \(videoURL)\n", stderr)
        NDJSONStreamer.writeError(VvxError(
            code:    .permissionDenied,
            message: "Could not resolve archive output directory.",
            url:     videoURL
        ))
        await failed.increment()
        return
    }

    let thumbCacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".vvx/thumbnails")

    let downloadConfig = DownloadJobConfig(
        url:                    videoURL,
        format:                 .bestVideo,
        isArchiveMode:          true,
        outputDirectory:        archiveRoot,
        ytDlpPath:              ytDlpURL,
        ffmpegPath:             resolver.resolvedFfmpegURL(),
        allSubtitleLanguages:   allSubs,
        requestHumanLikePacing: true
    )

    let downloader = VideoDownloader(thumbnailCacheDirectory: thumbCacheDir)

    for await event in downloader.download(config: downloadConfig) {
        switch event {

        case .completed(let metadata):
            NDJSONStreamer.syncProgressLine(
                index: slot, total: slotTotal,
                title: metadata.title, success: true
            )
            // Archive results emit VideoMetadata JSON (the download schema).
            CLIOutputFormatter.printJSON(metadata)
            await succeeded.increment()

            let wasIndexed = await indexMetadata(metadata, videoURL: videoURL)
            if wasIndexed { await indexed.increment() }

        case .failed(let error):
            NDJSONStreamer.syncProgressLine(
                index: slot, total: slotTotal,
                title: nil, success: false
            )
            NDJSONStreamer.writeError(error)
            await failed.increment()

            if error.code == .rateLimited {
                await coordinator.registerRateLimit()
            }

        default:
            break
        }
    }
}

// MARK: - Indexing helpers

/// Indexes a sense result into `vortex.db`.
///
/// Opens a **fresh** `VortexDB` connection per call — safe under WAL mode with
/// concurrent writers. Distinguishes between fatal corruption errors (loud stderr
/// warning) and transient busy timeouts (quiet log), per Mentor G / §5.2 guidance.
///
/// Returns `true` if indexing succeeded.
private func indexSenseResult(_ result: SenseResult, videoURL: String) async -> Bool {
    do {
        let db = try VortexDB.open()
        try await VortexIndexer.index(senseResult: result, db: db)
        return true
    } catch {
        classifyAndLogDBError(error, context: "sense", url: videoURL)
        return false
    }
}

/// Indexes a download/archive result into `vortex.db`. Returns `true` if succeeded.
private func indexMetadata(_ metadata: VideoMetadata, videoURL: String) async -> Bool {
    do {
        let db = try VortexDB.open()
        try await VortexIndexer.index(metadata: metadata, db: db)
        return true
    } catch {
        classifyAndLogDBError(error, context: "archive", url: videoURL)
        return false
    }
}

/// Logs a DB error to stderr, distinguishing fatal corruption from retryable busy.
private func classifyAndLogDBError(_ error: Error, context: String, url: String) {
    let msg = error.localizedDescription.lowercased()
    let isCritical = msg.contains("malformed") || msg.contains("corrupt") || msg.contains("disk image")
    if isCritical {
        fputs("✗ vvx sync [\(context)]: SQLITE_CORRUPT — database may be damaged. Run `vvx doctor`. URL: \(url)\n", stderr)
    } else {
        fputs("⚠ vvx sync [\(context)]: index skipped (\(error.localizedDescription)). URL: \(url)\n", stderr)
    }
}

// MARK: - Thread-safe counter

private actor SyncCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

// MARK: - Convenience

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
