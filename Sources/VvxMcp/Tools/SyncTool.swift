import Foundation
import VideoVortexCore

/// MCP implementation of the `sync` tool.
///
/// Channel / playlist ingest — mirrors SyncCommand behavior.
///
/// MCP transport rules applied here:
///   - `limit` is **required** (no default). Stops accidental unbounded syncs that
///     would exceed typical MCP client timeouts (~60 s, host-specific).
///   - All NDJSON output is **aggregated in memory** and returned as one text block.
///     CLI stderr progress is suppressed; per-item failures appear as structured lines.
///   - Concurrency: up to 3 workers, matching the CLI.
///
/// For large channels or full backfills tell the user to run `vvx sync …` in Terminal.
enum SyncTool {

    static func call(arguments: [String: Any]) async throws -> String {
        guard let url = arguments["url"] as? String, !url.isEmpty else {
            throw McpToolError.missingArgument("url")
        }
        guard let limit = arguments["limit"] as? Int else {
            throw McpToolError.missingArgument("limit")
        }

        let incremental  = arguments["incremental"]   as? Bool   ?? false
        let archive      = arguments["archive"]        as? Bool   ?? false
        let metadataOnly = arguments["metadataOnly"]   as? Bool   ?? false
        let allSubs      = arguments["allSubs"]        as? Bool   ?? false
        let noAutoUpdate = arguments["noAutoUpdate"]   as? Bool   ?? false
        let force        = arguments["force"]          as? Bool   ?? false
        let matchTitle   = arguments["matchTitle"]     as? String
        let afterDate    = arguments["afterDate"]      as? String

        let resolver = EngineResolver.cliResolver
        guard let ytDlpURL = resolver.resolvedYtDlpURL() else {
            let err = VvxError(code: .engineNotFound,
                               message: "yt-dlp not found.")
            return VvxErrorEnvelope(error: err).jsonString()
        }

        let config = VvxConfig.load()
        let outDir = config.resolvedTranscriptDirectory()

        // Accumulator for all output lines (aggregated instead of streaming to stdout).
        let collector = LineCollector()

        // DB connection for the incremental duplicate check.
        let dupCheckDB: VortexDB? = incremental ? (try? VortexDB.open()) : nil
        let coordinator = RateLimitCoordinator()

        let succeeded = SyncMcpCounter()
        let failed    = SyncMcpCounter()
        let indexed   = SyncMcpCounter()

        var newVideosEnqueued = 0

        // When --incremental is active, do NOT cap yt-dlp via --playlist-items
        // so we can keep scanning until `limit` *new* videos are found.
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
                    if incremental && !force {
                        let isDuplicate = (try? await dupCheckDB?.containsSensedVideo(id: videoURL)) ?? false
                        if isDuplicate {
                            await collector.append(skippedLine(url: videoURL))
                            continue streamLoop
                        }
                    }

                    if active >= 3 {
                        await group.next()
                        active -= 1
                    }

                    newVideosEnqueued += 1
                    let slot = newVideosEnqueued

                    let captureURL       = videoURL
                    let captureOutDir    = outDir
                    let captureYtDlp     = ytDlpURL
                    let captureResolver  = resolver
                    let captureAllSubs   = allSubs
                    let captureNoUpdate  = noAutoUpdate
                    let captureArchive   = archive
                    let captureMetaOnly  = metadataOnly
                    let captureLimit     = limit

                    group.addTask {
                        await runMcpSyncWorker(
                            videoURL:     captureURL,
                            slot:         slot,
                            slotTotal:    captureLimit,
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
                            indexed:      indexed,
                            collector:    collector
                        )
                    }
                    active += 1

                    if newVideosEnqueued == limit { break streamLoop }
                }
            } catch {
                let err = VvxError(code: .networkError,
                                   message: "Playlist resolution failed: \(error.localizedDescription)",
                                   url: url)
                await collector.append(VvxErrorEnvelope(error: err).jsonString())
            }

            for await _ in group {}
        }

        // Summary line appended last.
        let s = await succeeded.value
        let f = await failed.value
        let i = await indexed.value
        await collector.append(summaryLine(succeeded: s, failed: f, indexed: i,
                                           total: newVideosEnqueued))

        return await collector.joined()
    }
}

// MARK: - Worker (free function for Sendable)

private func runMcpSyncWorker(
    videoURL:     String,
    slot:         Int,
    slotTotal:    Int,
    outDir:       URL,
    ytDlpURL:     URL,
    resolver:     EngineResolver,
    allSubs:      Bool,
    noAutoUpdate: Bool,
    archive:      Bool,
    metadataOnly: Bool,
    coordinator:  RateLimitCoordinator,
    succeeded:    SyncMcpCounter,
    failed:       SyncMcpCounter,
    indexed:      SyncMcpCounter,
    collector:    LineCollector
) async {
    await coordinator.waitUntilSafeToProceed()

    if archive {
        await runMcpArchiveWorker(
            videoURL:     videoURL,
            ytDlpURL:     ytDlpURL,
            resolver:     resolver,
            allSubs:      allSubs,
            noAutoUpdate: noAutoUpdate,
            coordinator:  coordinator,
            succeeded:    succeeded,
            failed:       failed,
            indexed:      indexed,
            collector:    collector
        )
    } else {
        await runMcpSenseWorker(
            videoURL:     videoURL,
            outDir:       outDir,
            ytDlpURL:     ytDlpURL,
            allSubs:      allSubs,
            noAutoUpdate: noAutoUpdate,
            metadataOnly: metadataOnly,
            coordinator:  coordinator,
            succeeded:    succeeded,
            failed:       failed,
            indexed:      indexed,
            collector:    collector
        )
    }
}

private func runMcpSenseWorker(
    videoURL:     String,
    outDir:       URL,
    ytDlpURL:     URL,
    allSubs:      Bool,
    noAutoUpdate: Bool,
    metadataOnly: Bool,
    coordinator:  RateLimitCoordinator,
    succeeded:    SyncMcpCounter,
    failed:       SyncMcpCounter,
    indexed:      SyncMcpCounter,
    collector:    LineCollector
) async {
    let senseConfig = SenseConfig(
        url:                  videoURL,
        outputDirectory:      outDir,
        ytDlpPath:            ytDlpURL,
        allSubtitleLanguages: allSubs,
        requestHumanLikePacing: true
    )
    let senser = VideoSenser()

    for await event in senser.sense(config: senseConfig) {
        switch event {
        case .completed(let result):
            let output = metadataOnly ? result.withEmptyBlocks() : result
            await collector.append(encodeSenseResult(output))
            await succeeded.increment()

            if let db = try? VortexDB.open() {
                if (try? await VortexIndexer.index(senseResult: result, db: db)) != nil {
                    await indexed.increment()
                }
            }

        case .failed(let error):
            await collector.append(VvxErrorEnvelope(error: error).jsonString())
            await failed.increment()
            if error.code == .rateLimited {
                await coordinator.registerRateLimit()
            }

        default: break
        }
    }
}

private func runMcpArchiveWorker(
    videoURL:     String,
    ytDlpURL:     URL,
    resolver:     EngineResolver,
    allSubs:      Bool,
    noAutoUpdate: Bool,
    coordinator:  RateLimitCoordinator,
    succeeded:    SyncMcpCounter,
    failed:       SyncMcpCounter,
    indexed:      SyncMcpCounter,
    collector:    LineCollector
) async {
    guard let archiveRoot = MediaStoragePaths.archiveRoot() else {
        let err = VvxError(code: .permissionDenied,
                           message: "Could not resolve archive directory.",
                           url: videoURL)
        await collector.append(VvxErrorEnvelope(error: err).jsonString())
        await failed.increment()
        return
    }

    let thumbCacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".vvx/thumbnails")

    let dlConfig = DownloadJobConfig(
        url:                  videoURL,
        format:               .bestVideo,
        isArchiveMode:        true,
        outputDirectory:      archiveRoot,
        ytDlpPath:            ytDlpURL,
        ffmpegPath:           resolver.resolvedFfmpegURL(),
        allSubtitleLanguages: allSubs,
        requestHumanLikePacing: true
    )
    let downloader = VideoDownloader(thumbnailCacheDirectory: thumbCacheDir)

    for await event in downloader.download(config: dlConfig) {
        switch event {
        case .completed(let metadata):
            if let line = encodeMetadata(metadata) {
                await collector.append(line)
            }
            await succeeded.increment()

            if let db = try? VortexDB.open() {
                let config = VvxConfig.load()
                let outDir = config.resolvedTranscriptDirectory()
                let senseConfig = SenseConfig(
                    url:             videoURL,
                    outputDirectory: outDir,
                    ytDlpPath:       ytDlpURL
                )
                let senser = VideoSenser()
                for await senseEvent in senser.sense(config: senseConfig) {
                    if case .completed(let result) = senseEvent {
                        if (try? await VortexIndexer.index(senseResult: result, db: db)) != nil {
                            await indexed.increment()
                        }
                        break
                    }
                    if case .failed = senseEvent { break }
                }
            }

        case .failed(let error):
            await collector.append(VvxErrorEnvelope(error: error).jsonString())
            await failed.increment()
            if error.code == .rateLimited {
                await coordinator.registerRateLimit()
            }

        default: break
        }
    }
}

// MARK: - Helpers

private func encodeSenseResult(_ result: SenseResult) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(result),
          let str  = String(data: data, encoding: .utf8) else { return "{}" }
    return str
}

private func encodeMetadata(_ metadata: VideoMetadata) -> String? {
    guard let data = try? JSONEncoder().encode(metadata),
          let str  = String(data: data, encoding: .utf8) else { return nil }
    return str
}

private func skippedLine(url: String) -> String {
    let obj: [String: Any] = ["success": true, "skipped": true, "url": url, "reason": "already_in_vault"]
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let str  = String(data: data, encoding: .utf8) else { return "{}" }
    return str
}

private func summaryLine(succeeded: Int, failed: Int, indexed: Int, total: Int) -> String {
    let obj: [String: Any] = [
        "success":   true,
        "summary":   true,
        "succeeded": succeeded,
        "failed":    failed,
        "indexed":   indexed,
        "total":     total
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let str  = String(data: data, encoding: .utf8) else { return "{}" }
    return str
}

// MARK: - Thread-safe line collector

/// Accumulates NDJSON output lines in order for MCP aggregated response.
private actor LineCollector {
    private var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
    }

    func joined() -> String {
        lines.joined(separator: "\n")
    }
}

// MARK: - Thread-safe counter

private actor SyncMcpCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
