import Foundation

/// Indexes a completed sense or download result into `vortex.db`.
///
/// Called automatically by `VideoSenser` and `VideoDownloader` after every
/// successful operation.  This is the silent integration point that keeps
/// `vortex.db` current without any explicit user step.
///
/// Both methods are `async throws`.  Call sites in `VideoSenser` and
/// `VideoDownloader` wrap them with `try?` inside a `Task.detached` so that
/// a DB failure never propagates to the sense or fetch result.
public enum VortexIndexer {

    // MARK: - Public API

    /// Index a completed `sense` result.
    ///
    /// - Parses `senseResult.transcriptPath` with `SRTParser` (returns `[]` on nil/missing file).
    /// - Uses `chapterIndex` values pre-computed in `senseResult.transcriptBlocks` to populate
    ///   the `chapter_index` column in `transcript_blocks`.
    /// - Upserts the video record into `videos` (`videoPath` and `archivedAt` are left nil
    ///   because sense-only operations produce no media file).
    /// - Replaces all existing `transcript_blocks` for this URL in a single transaction
    ///   (delete-before-insert ensures re-sense is idempotent).
    public static func index(
        senseResult: SenseResult,
        db: VortexDB
    ) async throws {
        let now = iso8601(senseResult.completedAt)

        let record = VideoRecord(
            id:              senseResult.url,
            title:           senseResult.title,
            platform:        senseResult.platform,
            uploader:        senseResult.uploader,
            durationSeconds: senseResult.durationSeconds,
            uploadDate:      senseResult.uploadDate,
            transcriptPath:  senseResult.transcriptPath,
            videoPath:       nil,       // sense-only: no media file downloaded
            sensedAt:        now,
            archivedAt:      nil,       // sense-only
            tags:            senseResult.tags,
            viewCount:       senseResult.viewCount,
            likeCount:       senseResult.likeCount,
            commentCount:    senseResult.commentCount,
            description:     senseResult.description,
            chapters:        senseResult.chapters
        )

        try await db.upsertVideo(record)

        // Re-parse the SRT to get the [SRTBlock] values needed for DB storage
        // (string timestamps, etc.).  chapterIndex values come from the pre-computed
        // transcriptBlocks in the SenseResult so they match the JSON output exactly.
        let blocks         = blocksFromPath(senseResult.transcriptPath)
        let chapterIndices = senseResult.transcriptBlocks.map(\.chapterIndex)

        // Guardrail: sense with no transcript must not erase fetch-indexed FTS rows.
        // (Network yt-dlp may omit subs while archive `.srt` files already exist.)
        if blocks.isEmpty {
            let existing = try await db.transcriptBlockCount(forVideoId: senseResult.url)
            if existing > 0 { return }
        }

        try await db.upsertBlocks(
            blocks,
            videoId:        senseResult.url,
            title:          senseResult.title,
            platform:       senseResult.platform,
            uploader:       senseResult.uploader,
            chapterIndices: chapterIndices
        )
    }

    /// Index a completed `fetch` / `archive` result.
    ///
    /// - Parses the first `.srt` file in `metadata.subtitlePaths` with `SRTParser`.
    /// - Upserts the video record with `videoPath` set to `metadata.outputPath`
    ///   and `archivedAt` stamped (because the media file was downloaded).
    /// - Replaces all existing `transcript_blocks` for this URL.
    /// - `chapter_index` is stored as NULL for fetch results; run `vvx reindex` to backfill.
    public static func index(
        metadata: VideoMetadata,
        db: VortexDB
    ) async throws {
        let now    = iso8601(metadata.completedAt)
        let srtPath = metadata.subtitlePaths.first(where: { $0.hasSuffix(".srt") })

        let record = VideoRecord(
            id:              metadata.url,
            title:           metadata.title,
            platform:        metadata.platform,
            uploader:        nil,       // VideoMetadata carries no uploader field
            durationSeconds: metadata.durationSeconds,
            uploadDate:      nil,       // VideoMetadata carries no uploadDate field
            transcriptPath:  srtPath,
            videoPath:       metadata.outputPath,
            sensedAt:        now,
            archivedAt:      now,       // downloaded → archived
            tags:            [],
            viewCount:       nil,       // not available from VideoMetadata
            likeCount:       metadata.likeCount,
            commentCount:    metadata.commentCount,
            description:     nil
        )

        try await db.upsertVideo(record)

        let blocks = blocksFromPath(srtPath)
        try await db.upsertBlocks(
            blocks,
            videoId:  metadata.url,
            title:    metadata.title,
            platform: metadata.platform,
            uploader: nil
            // chapterIndices: [] — chapter mapping unavailable without sense data; use `vvx reindex`
        )
    }

    // MARK: - Reindex

    /// Reindex a **single** video record: re-parse its SRT file and backfill
    /// `chapter_index` using the same boundary logic as `buildSenseResult()`.
    ///
    /// Used by `ReindexCommand` for per-video progress streaming.
    /// Safe to call multiple times for the same video (idempotent — delete-before-insert).
    ///
    /// - Returns: `true` if blocks were updated; `false` if the SRT file is absent or empty.
    public static func reindexOne(record: VideoRecord, db: VortexDB) async throws -> Bool {
        let blocks = blocksFromPath(record.transcriptPath)
        guard !blocks.isEmpty else { return false }
        let chapters       = record.chapters.sorted { $0.startTime < $1.startTime }
        let chapterIndices = blocks.map { chapterIndex(for: $0.startSeconds, chapters: chapters) }
        try await db.upsertBlocks(
            blocks,
            videoId:        record.id,
            title:          record.title,
            platform:       record.platform,
            uploader:       record.uploader,
            chapterIndices: chapterIndices
        )
        return true
    }

    /// Reindex all videos in the database, backfilling `chapter_index` on every
    /// `transcript_blocks` row by re-running the chapter assignment logic against
    /// each video's stored SRT file and chapter metadata.
    ///
    /// Safe to run multiple times (idempotent — delete-before-insert).
    ///
    /// - Returns: `(reindexed, skipped)` where `skipped` counts videos whose SRT
    ///   file is missing or unreadable.
    public static func reindex(db: VortexDB) async throws -> (reindexed: Int, skipped: Int) {
        let videos = try await db.allVideos()
        var reindexed = 0
        var skipped   = 0

        for record in videos {
            let blocks = blocksFromPath(record.transcriptPath)
            guard !blocks.isEmpty else {
                skipped += 1
                continue
            }
            let chapters       = record.chapters.sorted { $0.startTime < $1.startTime }
            let chapterIndices = blocks.map { chapterIndex(for: $0.startSeconds, chapters: chapters) }
            try await db.upsertBlocks(
                blocks,
                videoId:        record.id,
                title:          record.title,
                platform:       record.platform,
                uploader:       record.uploader,
                chapterIndices: chapterIndices
            )
            reindexed += 1
        }

        return (reindexed, skipped)
    }

    // MARK: - Archive discovery (DR / migration rebuild)

    /// Minimal representation of a yt-dlp `.info.json` sidecar needed for archive
    /// discovery.  Only the fields required to build a `VideoRecord` are decoded —
    /// unknown keys are silently ignored by the `Decodable` synthesized implementation.
    private struct ArchivedInfoJSON: Decodable {
        let webpage_url:   String?
        let title:         String?
        let uploader:      String?
        let channel:       String?
        let extractor_key: String?
        let duration:      Double?
        let upload_date:   String?
        let description:   String?
        let tags:          [String]?
        let view_count:    Int?
        let like_count:    Int?
        let comment_count: Int?
        let chapters:      [ArchivedChapter]?

        struct ArchivedChapter: Decodable {
            let title:      String?
            let start_time: Double?
            let end_time:   Double?
        }
    }

    /// Walk `archiveDirectory` recursively for `.info.json` sidecars written by
    /// yt-dlp during `vvx fetch --archive`, and import each discovered video into `db`.
    ///
    /// This is the **disaster-recovery entry point**: when `vortex.db` is deleted or
    /// corrupt, running `rm ~/.vvx/vortex.db && vvx reindex` rebuilds the full index
    /// from on-disk truth.
    ///
    /// For every `.info.json`:
    ///   - Extracts URL, title, metadata, chapters, and engagement counts.
    ///   - Skips videos already in `db` (unless `force` is `true`).
    ///   - Finds the companion `.srt` in the same folder.
    ///   - Upserts a `VideoRecord` + transcript blocks with `chapter_index`.
    ///
    /// Sense-only transcripts in `~/.vvx/transcripts/` are NOT discoverable here
    /// because `vvx sense` uses `--no-write-info-json` — there is no sidecar to read
    /// the canonical URL from.  Those rows are only re-parseable when `vortex.db`
    /// already contains the URL; use `vvx reindex` (backfill phase) for them.
    ///
    /// - Parameters:
    ///   - archiveDirectory: Root of the archive tree (default `~/.vvx/archive/`).
    ///   - db: Target database actor.
    ///   - force: Re-import videos that are already present in `db`.
    ///   - progressCallback: Called for each `.info.json` examined.
    ///     Receives the video URL and whether it was newly imported (`true`) or
    ///     skipped (`false`).
    /// - Returns: `(discovered, skipped)` counts.
    public static func discoverArchived(
        in archiveDirectory: URL,
        db: VortexDB,
        force: Bool = false,
        progressCallback: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> (discovered: Int, skipped: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveDirectory.path) else { return (0, 0) }

        // Collect paths synchronously before entering the async loop — avoids the
        // Swift 6 warning about DirectoryEnumerator.makeIterator() being unavailable
        // from async contexts.
        let infoJSONURLs = collectInfoJSONURLs(in: archiveDirectory)

        var discovered = 0
        var skipped    = 0

        for fileURL in infoJSONURLs {

            guard let info    = parseArchivedInfoJSON(at: fileURL),
                  let videoURL = info.webpage_url, !videoURL.isEmpty else {
                skipped += 1
                continue
            }

            if !force, (try? await db.containsSensedVideo(id: videoURL)) == true {
                skipped += 1
                progressCallback?(videoURL, false)
                continue
            }

            let folder    = fileURL.deletingLastPathComponent()
            let srtPath   = findSRT(in: folder)
            let videoPath = findVideoFile(in: folder)
            let duration  = info.duration.map { Int($0.rounded()) }
            let chapters  = buildChapters(from: info.chapters, duration: duration)
            let platform  = info.extractor_key.map { LibraryPath.displayName(forExtractorFolder: $0) }
            let uploader  = info.uploader ?? info.channel
            let uploadDate = formatUploadDate(info.upload_date)
            let title = info.title
                ?? fileURL.deletingPathExtension().deletingPathExtension().lastPathComponent

            let now = iso8601(Date())
            let record = VideoRecord(
                id:              videoURL,
                title:           title,
                platform:        platform,
                uploader:        uploader,
                durationSeconds: duration,
                uploadDate:      uploadDate,
                transcriptPath:  srtPath,
                videoPath:       videoPath,
                sensedAt:        now,
                archivedAt:      now,
                tags:            info.tags ?? [],
                viewCount:       info.view_count,
                likeCount:       info.like_count,
                commentCount:    info.comment_count,
                description:     info.description,
                chapters:        chapters
            )

            try await db.upsertVideo(record)

            let blocks         = blocksFromPath(srtPath)
            let sortedChapters = chapters.sorted { $0.startTime < $1.startTime }
            let chapterIndices = blocks.map { chapterIndex(for: $0.startSeconds, chapters: sortedChapters) }
            try await db.upsertBlocks(
                blocks,
                videoId:        videoURL,
                title:          title,
                platform:       platform,
                uploader:       uploader,
                chapterIndices: chapterIndices
            )

            discovered += 1
            progressCallback?(videoURL, true)
        }

        return (discovered, skipped)
    }

    // MARK: - Private helpers

    /// Parse an SRT file at `path` into `[SRTBlock]`.  Returns `[]` when `path`
    /// is nil, the file is missing, or the content is unreadable.
    private static func blocksFromPath(_ path: String?) -> [SRTBlock] {
        guard let path,
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return SRTParser.parse(raw)
    }

    /// Find the zero-based chapter index for a block at `startSeconds`.
    ///
    /// Returns the index of the last chapter whose `startTime` is ≤ `startSeconds`.
    /// Returns `nil` when `chapters` is empty or the block precedes all chapter markers.
    private static func chapterIndex(for startSeconds: Double, chapters: [VideoChapter]) -> Int? {
        guard !chapters.isEmpty else { return nil }
        var best: Int? = nil
        for (i, ch) in chapters.enumerated() {
            if ch.startTime <= startSeconds { best = i } else { break }
        }
        return best
    }

    // `nonisolated(unsafe)` suppresses the strict-concurrency warning — the formatter
    // is only ever written once (at first access) and its format string never changes.
    nonisolated(unsafe) private static let _formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func iso8601(_ date: Date) -> String {
        _formatter.string(from: date)
    }

    // MARK: - Archive discovery private helpers

    /// Collect all `.info.json` file URLs under `directory` (recursive, hidden files skipped).
    /// Runs synchronously so it can be called from non-async helpers without triggering the
    /// Swift 6 warning on `DirectoryEnumerator.makeIterator()`.
    private static func collectInfoJSONURLs(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".info.json") {
            result.append(url)
        }
        return result
    }

    private static func parseArchivedInfoJSON(at url: URL) -> ArchivedInfoJSON? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ArchivedInfoJSON.self, from: data)
    }

    /// Find the best `.srt` companion in `folder`.
    /// Prefers `.en.srt`, then `.en-orig.srt`, then any `.srt`.
    private static func findSRT(in folder: URL) -> String? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) else { return nil }
        let srts = items.filter { $0.pathExtension.lowercased() == "srt" }
        if let en     = srts.first(where: { $0.lastPathComponent.contains(".en.") })      { return en.path }
        if let enOrig = srts.first(where: { $0.lastPathComponent.contains(".en-orig.") }) { return enOrig.path }
        return srts.first?.path
    }

    /// Find the video media file (`.mp4`, `.mkv`, `.webm`, `.m4v`, `.mov`) in `folder`.
    private static func findVideoFile(in folder: URL) -> String? {
        let videoExts = Set(["mp4", "mkv", "webm", "m4v", "mov"])
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) else { return nil }
        return items.first { videoExts.contains($0.pathExtension.lowercased()) }?.path
    }

    /// Convert yt-dlp chapters array to `[VideoChapter]`, computing `endTime` from
    /// successive start times or the total video duration for the last chapter.
    private static func buildChapters(
        from ytChapters: [ArchivedInfoJSON.ArchivedChapter]?,
        duration: Int?
    ) -> [VideoChapter] {
        guard let raw = ytChapters, !raw.isEmpty else { return [] }
        let sorted = raw.sorted { ($0.start_time ?? 0) < ($1.start_time ?? 0) }
        return sorted.enumerated().map { i, ch in
            let start = ch.start_time ?? 0
            let end: Double?
            if i + 1 < sorted.count {
                end = sorted[i + 1].start_time
            } else if let dur = duration {
                end = Double(dur)
            } else {
                end = ch.end_time
            }
            return VideoChapter(
                title:     ch.title ?? "Chapter \(i + 1)",
                startTime: start,
                endTime:   end
            )
        }
    }

    /// Convert yt-dlp `upload_date` "YYYYMMDD" → ISO 8601 "YYYY-MM-DD".
    private static func formatUploadDate(_ raw: String?) -> String? {
        guard let raw, raw.count == 8 else { return nil }
        let y = raw.prefix(4)
        let m = raw.dropFirst(4).prefix(2)
        let d = raw.dropFirst(6).prefix(2)
        return "\(y)-\(m)-\(d)"
    }
}
