import Foundation
#if os(macOS)
import AVFoundation
import CoreMedia
#endif

// MARK: - IngestConfig

public struct IngestConfig: Sendable {
    /// Resolved absolute root directory to walk.
    public let rootURL:      URL
    /// When true: full walk + sidecar resolution, but no DB writes and no ffprobe.
    public let dryRun:       Bool
    /// When true: bypass dedup check and re-upsert existing paths.
    public let forceReindex: Bool
    /// File extensions (lowercase, without dot) treated as video candidates. Default `["mp4"]`.
    public let extensions:   [String]

    public init(
        rootURL:      URL,
        dryRun:       Bool     = false,
        forceReindex: Bool     = false,
        extensions:   [String] = ["mp4"]
    ) {
        self.rootURL      = rootURL
        self.dryRun       = dryRun
        self.forceReindex = forceReindex
        self.extensions   = extensions
    }
}

// MARK: - IngestEngine

/// Recursively scans a local directory for video files, matches sibling sidecars
/// (`.srt`, `.info.json`), and indexes discovered media into `vortex.db` using
/// absolute paths — without moving, copying, or modifying any user files.
///
/// **Console-free:** no direct `print` or stderr writes. Progress is surfaced via
/// the optional `progress` callback so the CLI can emit stderr heartbeats while
/// MCP can omit or no-op the callback.
///
/// Pattern: same as `GatherEngine` / `SearchEngine` — one behaviour, two surfaces (CLI + MCP).
public enum IngestEngine {

    // MARK: - Private: info.json shape

    /// Minimal yt-dlp `.info.json` fields needed for archive-style metadata.
    /// Unknown keys are silently ignored by the synthesized `Decodable` implementation.
    private struct IngestInfoJSON: Decodable {
        let webpage_url:   String?
        let id:            String?
        let title:         String?
        let duration:      Double?
        let uploader:      String?
        let channel:       String?
        let upload_date:   String?
        let description:   String?
        let tags:          [String]?
        let view_count:    Int?
        let like_count:    Int?
        let comment_count: Int?
        let chapters:      [RawChapter]?

        struct RawChapter: Decodable {
            let title:      String?
            let start_time: Double?
            let end_time:   Double?
        }

        /// Locked validity rule (spec §Phase 1, item 5):
        /// Valid iff `webpage_url` is a non-empty string,
        /// OR (`id` is non-empty AND `title` is non-empty AND `duration` is a number).
        var isValidYtDlpShape: Bool {
            if let url = webpage_url, !url.isEmpty { return true }
            if let vid = id, !vid.isEmpty,
               let t   = title, !t.isEmpty,
               duration != nil { return true }
            return false
        }
    }

    // MARK: - Private: info.json parse result

    private struct InfoJSONResult {
        /// Decoded struct — nil when file not found, unreadable, or fails JSON decode.
        var info:       IngestInfoJSON?
        /// True when the JSON parsed but failed the locked validity rule → local fallback
        /// + increment `malformed_info_json_count` in summary.
        var malformed:  Bool
        /// True when the file exists but `Data(contentsOf:)` threw → `invalid_sidecar` count.
        var unreadable: Bool
    }

    // MARK: - Private: NDJSON line collector actor

    private actor LineCollector {
        private var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
        func joined() -> String     { lines.joined(separator: "\n") }
    }

    // MARK: - Public: Entry point

    /// Run a full ingest operation and return the aggregated NDJSON string.
    ///
    /// - Parameters:
    ///   - config:   All ingest flags.
    ///   - db:       Optional pre-opened `VortexDB`. When `nil` (default), opens
    ///               `~/.vvx/vortex.db` via `VortexDB.open()`. Pass an isolated
    ///               instance in tests to avoid touching the production database.
    ///   - progress: Optional callback: `(filesChecked, indexed, dryRun)`.
    ///               CLI passes `{ c, i, d in stderrLine("...") }`. MCP passes `nil`.
    /// - Returns: Newline-joined NDJSON lines. Last line is always `IngestSummaryLine`.
    ///   On fatal errors (bad root path, DB open failure), returns a single
    ///   `VvxErrorEnvelope` JSON string and does NOT throw.
    public static func run(
        config:   IngestConfig,
        db:       VortexDB?                    = nil,
        progress: ((Int, Int, Bool) -> Void)?  = nil
    ) async -> String {

        let collector = LineCollector()

        // --- Validate root path (fast-fail before DB open) ---
        var isDir: ObjCBool = false
        let rootExists = FileManager.default.fileExists(
            atPath: config.rootURL.path, isDirectory: &isDir
        )
        guard rootExists, isDir.boolValue else {
            let msg = rootExists
                ? "Ingest root is not a directory: \(config.rootURL.path)"
                : "Ingest root does not exist: \(config.rootURL.path)"
            return VvxErrorEnvelope(error: VvxError(
                code:    .permissionDenied,
                message: msg
            )).jsonString()
        }

        // --- Open DB (or use injected instance) ---
        let resolvedDB: VortexDB
        if let injected = db {
            resolvedDB = injected
        } else {
            do { resolvedDB = try VortexDB.open() } catch {
                return VvxErrorEnvelope(error: VvxError(
                    code:    .indexCorrupt,
                    message: "Could not open vortex.db: \(error.localizedDescription)"
                )).jsonString()
            }
        }
        let db = resolvedDB

        // --- Collect video candidates (sync — avoids Swift 6 async enumerator warning) ---
        let extSet = Set(config.extensions.map { $0.lowercased() })
        let (candidates, nonVideoCount, traversalErrors) = collectVideoCandidates(
            in:         config.rootURL,
            extensions: extSet
        )

        // --- Counters ---
        var indexed           = 0
        var alreadyIndexed    = 0
        var invalidSidecar    = 0
        var corruptMedia      = 0
        var malformedInfoJSON = 0
        var errorsLogged      = traversalErrors
        var filesChecked      = 0

        let now = iso8601(Date())

        // --- Process each video candidate ---
        for candidate in candidates {
            filesChecked += 1

            // Progress heartbeat every 100 files
            if filesChecked % 100 == 0 {
                progress?(filesChecked, indexed, config.dryRun)
            }

            let absPath = candidate.path
            let stem    = candidate.deletingPathExtension().lastPathComponent
            let folder  = candidate.deletingLastPathComponent()

            // --- Deduplication ---
            if !config.forceReindex {
                let alreadyIn: Bool
                do {
                    alreadyIn = try await db.containsSensedVideo(id: absPath)
                } catch {
                    errorsLogged += 1
                    continue
                }
                if alreadyIn {
                    alreadyIndexed += 1
                    await collector.append(encode(
                        IngestResultLine.skipped(path: absPath, reason: .alreadyIndexed)
                    ))
                    continue
                }
            }

            // --- Sidecar discovery ---
            let srtPath    = findSRT(stem: stem, folder: folder)
            let infoResult = findAndParseInfoJSON(stem: stem, folder: folder)
            if infoResult.malformed  { malformedInfoJSON += 1 }
            if infoResult.unreadable { invalidSidecar    += 1 }

            // --- Metadata from info.json or filename fallback ---
            let title:        String
            let uploader:     String?
            let uploadDate:   String?
            let tags:         [String]
            let viewCount:    Int?
            let likeCount:    Int?
            let commentCount: Int?
            let chapters:     [VideoChapter]
            var infoDuration: Int? = nil

            if let info = infoResult.info, info.isValidYtDlpShape {
                title        = info.title ?? stem
                uploader     = info.uploader ?? info.channel
                uploadDate   = formatUploadDate(info.upload_date)
                tags         = info.tags ?? []
                viewCount    = info.view_count
                likeCount    = info.like_count
                commentCount = info.comment_count
                chapters     = buildChapters(
                    from:     info.chapters,
                    duration: info.duration.map { Int($0.rounded()) }
                )
                if let dur = info.duration, dur > 0 {
                    infoDuration = Int(dur.rounded())
                }
            } else {
                // Pure local fallback: filename stem as title, no URL/platform metadata.
                title        = stem
                uploader     = nil
                uploadDate   = nil
                tags         = []
                viewCount    = nil
                likeCount    = nil
                commentCount = nil
                chapters     = []
            }

            // --- Duration probe (spec: no ffprobe in dry-run) ---
            var durationSeconds: Int? = infoDuration
            if durationSeconds == nil && !config.dryRun {
                durationSeconds = await probeDuration(for: candidate)
            }

            // --- Transcript (SRT) ---
            let transcriptSource: String
            let blocks:           [SRTBlock]

            if let srtPath {
                if let raw = try? String(contentsOfFile: srtPath, encoding: .utf8) {
                    let parsed = SRTParser.parse(raw)
                    if parsed.isEmpty {
                        // SRT present but yields no usable blocks — still index the video.
                        blocks           = []
                        transcriptSource = "none"
                        invalidSidecar  += 1
                    } else {
                        blocks           = parsed
                        transcriptSource = "local"
                    }
                } else {
                    // SRT file exists but is unreadable.
                    blocks           = []
                    transcriptSource = "none"
                    invalidSidecar  += 1
                }
            } else {
                blocks           = []
                transcriptSource = "none"
            }

            // --- DB write (skipped in dry-run) ---
            if !config.dryRun {
                let record = VideoRecord(
                    id:              absPath,   // absolute path is the unique id for local files
                    title:           title,
                    platform:        nil,        // no platform for locally ingested media
                    uploader:        uploader,
                    durationSeconds: durationSeconds,
                    uploadDate:      uploadDate,
                    transcriptPath:  srtPath,
                    videoPath:       absPath,
                    sensedAt:        now,
                    archivedAt:      now,        // file is local and accessible
                    tags:            tags,
                    viewCount:       viewCount,
                    likeCount:       likeCount,
                    commentCount:    commentCount,
                    description:     nil,
                    chapters:        chapters
                )

                do {
                    try await db.upsertVideo(record)
                } catch {
                    corruptMedia += 1
                    errorsLogged += 1
                    await collector.append(encode(
                        IngestResultLine.skipped(path: absPath, reason: .corruptMedia)
                    ))
                    continue
                }

                if !blocks.isEmpty {
                    let sortedChapters = chapters.sorted { $0.startTime < $1.startTime }
                    let chapterIndices = blocks.map {
                        chapterIndexFor($0.startSeconds, chapters: sortedChapters)
                    }
                    do {
                        try await db.upsertBlocks(
                            blocks,
                            videoId:        absPath,
                            title:          title,
                            platform:       nil,
                            uploader:       uploader,
                            chapterIndices: chapterIndices
                        )
                    } catch {
                        // Video row upserted successfully; block upsert failed.
                        // Log but do not demote to corruptMedia — the video IS indexed.
                        errorsLogged += 1
                    }
                }
            }

            indexed += 1
            await collector.append(encode(IngestResultLine.indexed(
                path:             absPath,
                videoId:          absPath,
                title:            title,
                durationSeconds:  durationSeconds,
                transcriptSource: transcriptSource
            )))
        }

        // Final progress flush (fires even if total < 100 files).
        progress?(filesChecked, indexed, config.dryRun)

        // --- Summary ---
        // `skipped` total = sum of all four skipped_reasons (spec example math).
        let totalSkipped = nonVideoCount + alreadyIndexed + invalidSidecar + corruptMedia
        await collector.append(encode(IngestSummaryLine(
            indexed:                indexed,
            skipped:                totalSkipped,
            skippedReasons:         IngestSkippedReasons(
                nonVideo:       nonVideoCount,
                alreadyIndexed: alreadyIndexed,
                invalidSidecar: invalidSidecar,
                corruptMedia:   corruptMedia
            ),
            malformedInfoJsonCount: malformedInfoJSON,
            errorsLogged:           errorsLogged,
            dryRun:                 config.dryRun
        )))
        return await collector.joined()
    }

    // MARK: - Private: Directory traversal (synchronous)

    /// Collect video file URLs from `root` recursively.
    ///
    /// Runs **synchronously** before the async processing loop — avoids the Swift 6
    /// warning about `DirectoryEnumerator.makeIterator()` being unavailable in async contexts.
    ///
    /// - Skips hidden files and package descendants (`.git`, `.app` bundles, dotfolders).
    /// - Skips symlinks (prevents cycles and surprise paths outside the intended tree).
    /// - Returns: `(videos, nonVideoCount, traversalErrors)`.
    private static func collectVideoCandidates(
        in root:     URL,
        extensions:  Set<String>
    ) -> (videos: [URL], nonVideoCount: Int, traversalErrors: Int) {

        guard let enumerator = FileManager.default.enumerator(
            at:                        root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options:                   [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], 0, 1) }

        var videos:         [URL] = []
        var nonVideoCount         = 0
        var traversalErrors       = 0

        for case let url as URL in enumerator {
            do {
                let rv = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                // Spec §C: skip symlinks to prevent cycles and surprise paths.
                if rv.isSymbolicLink == true { continue }
                // Only process regular files (directories are traversed automatically).
                guard rv.isRegularFile == true else { continue }
            } catch {
                traversalErrors += 1
                continue
            }

            if extensions.contains(url.pathExtension.lowercased()) {
                videos.append(url)
            } else {
                nonVideoCount += 1
            }
        }

        return (videos, nonVideoCount, traversalErrors)
    }

    // MARK: - Private: Sidecar helpers

    /// Find the best SRT companion for a video with the given stem in `folder`.
    ///
    /// Matches only companions whose name begins with `<stem>.` so unrelated SRTs
    /// in the same directory are never picked up.
    /// Preference: `.en.srt` → `.en-orig.srt` → any `.srt` with matching stem.
    private static func findSRT(stem: String, folder: URL) -> String? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) else { return nil }

        let prefix = stem + "."
        let srts = items.filter {
            $0.pathExtension.lowercased() == "srt" &&
            $0.lastPathComponent.hasPrefix(prefix)
        }
        if let en     = srts.first(where: { $0.lastPathComponent.contains(".en.") })      { return en.path }
        if let enOrig = srts.first(where: { $0.lastPathComponent.contains(".en-orig.") }) { return enOrig.path }
        return srts.first?.path
    }

    /// Find and parse the `<stem>.info.json` companion in `folder`.
    ///
    /// - Returns an `InfoJSONResult` carrying:
    ///   - `info`: decoded struct (valid shape only; nil otherwise).
    ///   - `malformed`: JSON parsed but failed locked validity rule → `malformed_info_json_count++`.
    ///   - `unreadable`: file exists but `Data(contentsOf:)` threw → `invalid_sidecar` count.
    private static func findAndParseInfoJSON(
        stem:   String,
        folder: URL
    ) -> InfoJSONResult {
        let candidate = folder.appendingPathComponent("\(stem).info.json")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return InfoJSONResult(info: nil, malformed: false, unreadable: false)
        }
        guard let data = try? Data(contentsOf: candidate) else {
            return InfoJSONResult(info: nil, malformed: false, unreadable: true)
        }
        guard let parsed = try? JSONDecoder().decode(IngestInfoJSON.self, from: data) else {
            // Bytes on disk but not valid JSON at all — treat as malformed (not unreadable).
            return InfoJSONResult(info: nil, malformed: true, unreadable: false)
        }
        // JSON parses but fails the locked yt-dlp shape check → malformed, local fallback.
        if !parsed.isValidYtDlpShape {
            return InfoJSONResult(info: nil, malformed: true, unreadable: false)
        }
        return InfoJSONResult(info: parsed, malformed: false, unreadable: false)
    }

    // MARK: - Private: Duration probe

    /// Probe the duration of a local video file.
    ///
    /// macOS: AVFoundation async (`asset.load(.duration)`) — no subprocess.
    /// Linux: synchronous ffprobe subprocess (same approach as `DownloadCompletionPostProcessor`).
    /// Returns `nil` when the file cannot be probed (tool not found, file unreadable, etc.).
    private static func probeDuration(for url: URL) async -> Int? {
#if os(macOS)
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration) else { return nil }
        let sec = CMTimeGetSeconds(dur)
        guard sec.isFinite, sec > 0 else { return nil }
        return Int(sec.rounded())
#else
        return probeDurationViaFFprobe(at: url)
#endif
    }

#if !os(macOS)
    private static func probeDurationViaFFprobe(at url: URL) -> Int? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var ffprobeURL: URL?
        for dir in pathEnv.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: "\(dir)/ffprobe")
            if FileManager.default.fileExists(atPath: candidate.path) {
                ffprobeURL = candidate
                break
            }
        }
        guard let ffprobeURL else { return nil }

        let proc = Process()
        proc.executableURL = ffprobeURL
        proc.arguments     = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let raw = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, let secs = Double(raw), secs > 0 else { return nil }
        return Int(secs.rounded())
    }
#endif

    // MARK: - Private: Chapter utilities

    /// Assign the zero-based chapter index for a transcript block at `startSeconds`.
    /// Returns the last chapter whose `startTime ≤ startSeconds`; nil when none.
    private static func chapterIndexFor(
        _ startSeconds: Double,
        chapters:       [VideoChapter]
    ) -> Int? {
        guard !chapters.isEmpty else { return nil }
        var best: Int? = nil
        for (i, ch) in chapters.enumerated() {
            if ch.startTime <= startSeconds { best = i } else { break }
        }
        return best
    }

    /// Build `[VideoChapter]` from a raw yt-dlp chapters array.
    /// End times are derived from successive start times, or from `duration` for the last chapter.
    private static func buildChapters(
        from raw:  [IngestInfoJSON.RawChapter]?,
        duration:  Int?
    ) -> [VideoChapter] {
        guard let raw, !raw.isEmpty else { return [] }
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
            return VideoChapter(title: ch.title ?? "Chapter \(i + 1)", startTime: start, endTime: end)
        }
    }

    // MARK: - Private: Date formatter

    /// Convert yt-dlp `upload_date` "YYYYMMDD" → ISO 8601 "YYYY-MM-DD".
    private static func formatUploadDate(_ raw: String?) -> String? {
        guard let raw, raw.count == 8 else { return nil }
        return "\(raw.prefix(4))-\(raw.dropFirst(4).prefix(2))-\(raw.dropFirst(6).prefix(2))"
    }

    // MARK: - Private: ISO 8601 timestamp

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

    // MARK: - Private: NDJSON encoding helper

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return "" }
        return line
    }
}
