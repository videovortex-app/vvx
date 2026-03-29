import Foundation
import Logging
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Sense milestone phases

/// Logical phase milestones emitted during a sense operation.
/// Each fires at most once per run. Detection is best-effort against yt-dlp stderr.
public enum SenseMilestone: String, Sendable, Hashable, CaseIterable {
    case preparingRequest     = "Preparing request..."
    case connectingToPlatform = "Connecting to platform..."
    case downloadingMetadata  = "Downloading metadata..."
    case extractingTranscript = "Extracting transcript..."

    public var label: String { rawValue }
}

// MARK: - Sense progress events

public enum SenseProgress: Sendable {
    /// yt-dlp process is starting.
    case preparing
    /// A logical phase milestone — human-readable progress for CLI and MCP logging.
    case milestone(SenseMilestone)
    /// yt-dlp exited non-zero; engine was refreshed; sense restarting.
    case retrying
    /// yt-dlp finished and produced a result.
    case completed(SenseResult)
    /// yt-dlp exited with a typed error.
    case failed(VvxError)
}

// MARK: - Sense configuration

public struct SenseConfig: Sendable {
    /// The video URL to sense.
    public let url: String

    /// Where yt-dlp writes extracted .srt files.
    /// Corresponds to `VvxConfig.resolvedTranscriptDirectory()`.
    public let outputDirectory: URL

    /// Path to the yt-dlp binary (from EngineResolver).
    public let ytDlpPath: URL

    /// Browser name for cookie extraction (safari, chrome, firefox, edge).
    public let browserCookies: String?

    /// Strip SponsorBlock sponsor segments from transcript when true.
    public let removeSponsorSegments: Bool

    /// Maximum seconds to wait for yt-dlp before terminating the subprocess and
    /// returning a timeout error. Defaults to 120 seconds.
    public let timeoutSeconds: Double

    /// When true, use `--sub-langs en.*` instead of the safer default (`en,en-orig`).
    public let allSubtitleLanguages: Bool

    /// When true, append yt-dlp sleep pacing between internal HTTP requests.
    public let requestHumanLikePacing: Bool

    public init(
        url: String,
        outputDirectory: URL,
        ytDlpPath: URL,
        browserCookies: String? = nil,
        removeSponsorSegments: Bool = false,
        timeoutSeconds: Double = 120,
        allSubtitleLanguages: Bool = false,
        requestHumanLikePacing: Bool = false
    ) {
        self.url                   = url
        self.outputDirectory       = outputDirectory
        self.ytDlpPath             = ytDlpPath
        self.browserCookies        = browserCookies
        self.removeSponsorSegments = removeSponsorSegments
        self.timeoutSeconds        = timeoutSeconds
        self.allSubtitleLanguages  = allSubtitleLanguages
        self.requestHumanLikePacing = requestHumanLikePacing
    }
}

// MARK: - VideoSenser

/// Runs yt-dlp in "sense" mode: extracts metadata + transcript without downloading media.
///
/// The hero operation of vvx. Fast (seconds), zero disk footprint beyond the .srt file.
/// Lets agents "read" a video the same way Firecrawl lets them "read" a web page.
public final class VideoSenser: Sendable {

    private let logger = Logger(label: "com.videovortex.core.VideoSenser")

    public init() {}

    // MARK: - yt-dlp output template for sense mode

    /// Stores transcripts at:
    ///   <outputDir>/<extractor_key>/<uploader>/<title>.en.srt
    private static let outputTemplate =
        "%(extractor_key)s/%(uploader,channel,NA)s/%(title).50B.%(ext)s"

    // MARK: - Public API

    /// Starts a sense operation and returns an async stream of progress events.
    /// The stream always ends with `.completed` or `.failed`.
    /// On yt-dlp failure, automatically checks for and installs a newer yt-dlp
    /// version, then retries exactly once before reporting failure.
    public func sense(config: SenseConfig) -> AsyncStream<SenseProgress> {
        let (stream, continuation) = AsyncStream<SenseProgress>.makeStream()

        Task.detached(priority: .userInitiated) { [self] in
            continuation.yield(.preparing)

            do {
                try FileManager.default.createDirectory(
                    at: config.outputDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                continuation.yield(.failed(VvxError(
                    code: .permissionDenied,
                    message: "Could not create transcript directory: \(error.localizedDescription)",
                    url: config.url
                )))
                continuation.finish()
                return
            }

            let args = Self.buildArguments(config: config)

            // Fire the first milestone: directory exists, process is about to launch.
            continuation.yield(.milestone(.preparingRequest))

            // Relay subsequent milestones detected from yt-dlp stderr.
            let milestoneCallback: @Sendable (SenseMilestone) -> Void = { m in
                continuation.yield(.milestone(m))
            }

            var run = await Self.runSenseProcess(config: config, args: args,
                                                 milestoneCallback: milestoneCallback)

            // HTTP 429 backoff: retry with increasing delays before other recovery paths.
            var rateIdx = 0
            while run.exitCode != 0 && YtDlpRateLimit.isProbablyRateLimited(run.stderrText)
                && rateIdx < YtDlpRateLimit.backoffSecondsBeforeRetry.count {
                YtDlpRateLimit.printBackoffNotice(attemptIndex: rateIdx)
                let delay = YtDlpRateLimit.backoffSecondsBeforeRetry[rateIdx]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                rateIdx += 1
                run = await Self.runSenseProcess(config: config, args: args,
                                                  milestoneCallback: milestoneCallback)
            }

            if run.exitCode != 0 {
                // Emit a guided upgrade hint when the failure looks like a stale extractor.
                if Self.looksLikeExtractorError(run.stderrText) {
                    fputs(Self.guidedUpdateMessage, stderr)
                }
                self.logger.error("VideoSenser: yt-dlp exited \(run.exitCode). stderr: \(run.stderrText)")
                continuation.yield(.failed(
                    VvxError.fromYtDlpStderr(run.stderrText, url: config.url)
                ))
                continuation.finish()
                return
            }

            guard let infoDict = self.parseInfoDict(run.stdoutData) else {
                continuation.yield(.failed(VvxError(
                    code: .parseError,
                    message: "Could not parse yt-dlp metadata JSON.",
                    url: config.url,
                    detail: String(data: run.stdoutData.prefix(500), encoding: .utf8)
                )))
                continuation.finish()
                return
            }

            var (srtPath, srtLang) = self.findSRTFile(
                in: config.outputDirectory,
                info: infoDict
            )
            var fromLocalVault = false
            if srtPath == nil,
               let vault = self.findLocalVaultSubtitle(canonicalURL: config.url, info: infoDict) {
                srtPath = vault.path
                srtLang = vault.lang
                fromLocalVault = true
            }

            let result = self.buildSenseResult(
                url: config.url,
                info: infoDict,
                transcriptPath: srtPath,
                transcriptLanguage: srtLang,
                fromLocalVault: fromLocalVault
            )

            // Await indexing inline (same outer task) so the SQLite write completes
            // before the CLI process exits.  Errors are logged but do not fail the
            // sense operation — transcript JSON is still returned on success.
            do {
                let db = try VortexDB.open()
                try await VortexIndexer.index(senseResult: result, db: db)
            } catch {
                self.logger.error("VideoSenser: indexing failed — \(error)")
            }

            continuation.yield(.completed(result))
            continuation.finish()
        }

        return stream
    }

    // MARK: - Argument builder

    private static func buildArguments(config: SenseConfig) -> [String] {
        var args: [String] = []
        if let browser = config.browserCookies {
            args.append(contentsOf: ["--cookies-from-browser", browser])
        }
        if config.removeSponsorSegments {
            args.append(contentsOf: ["--sponsorblock-remove", "sponsor"])
        }
        let subLangs = config.allSubtitleLanguages
            ? YtDlpRateLimit.allSubsSubLangs
            : YtDlpRateLimit.defaultSubLangs
        args.append(contentsOf: [
            "--dump-json",
            "--write-auto-subs",
            "--write-subs",
            "--sub-langs", subLangs,
            "--skip-download",
            "--convert-subs", "srt",
            "--no-write-info-json",
            "--no-mtime",
            "--no-color",
        ])
        if config.requestHumanLikePacing {
            args.append(contentsOf: ["--sleep-requests", "1", "--sleep-interval", "2"])
        }
        args.append(contentsOf: ["-o", outputTemplate, config.url])
        return args
    }

    // MARK: - Process runner (shared between first attempt and retry)

    private struct SenseRunResult {
        let exitCode: Int32
        let stdoutData: Data
        let stderrText: String
    }

    // Thin @unchecked Sendable wrapper so Process can cross task boundaries safely.
    // We never access the process concurrently — the wrapper just suppresses the
    // Sendable diagnostic while we manage lifetime manually.
    private final class SendableProcess: @unchecked Sendable {
        let value: Process
        init(_ p: Process) { value = p }
    }

    // Thread-safe accumulator for pipe data collected by readabilityHandlers.
    //
    // readabilityHandler fires on a private GCD thread. Under Swift 6 strict
    // concurrency, mutating outer `var`s captured from an async frame is a data
    // race. This class serialises all mutations behind an NSLock so the closures
    // only ever capture a single `let` reference.
    private final class SensePipeState: @unchecked Sendable {
        private let _lock            = NSLock()
        private var _stdoutData      = Data()
        private var _stderrData      = Data()
        private var _firedMilestones = Set<SenseMilestone>()

        func appendStdout(_ data: Data) {
            _lock.lock(); defer { _lock.unlock() }
            _stdoutData.append(data)
        }

        func appendStderr(_ data: Data) {
            _lock.lock(); defer { _lock.unlock() }
            _stderrData.append(data)
        }

        /// Parses a chunk of stderr text and returns any milestones that fire for the
        /// first time. Each milestone fires at most once per `SensePipeState` instance.
        /// The lock is released before returning so callers can invoke callbacks safely.
        func checkMilestones(in text: String) -> [SenseMilestone] {
            _lock.lock()
            var triggered: [SenseMilestone] = []
            for line in text.components(separatedBy: "\n") {
                // First extractor bracket line (e.g. "[youtube] …") → platform connected.
                // Exclude [info] and [download] which appear later in the pipeline.
                if !_firedMilestones.contains(.connectingToPlatform),
                   line.hasPrefix("["),
                   !line.hasPrefix("[info]"),
                   !line.hasPrefix("[download]") {
                    _firedMilestones.insert(.connectingToPlatform)
                    triggered.append(.connectingToPlatform)
                }
                // API/player JSON download lines → metadata phase. Requires the
                // connecting milestone to have fired first so these are ordered.
                if !_firedMilestones.contains(.downloadingMetadata),
                   _firedMilestones.contains(.connectingToPlatform),
                   line.contains("Downloading"),
                   line.contains("JSON") || line.contains("player") {
                    _firedMilestones.insert(.downloadingMetadata)
                    triggered.append(.downloadingMetadata)
                }
                // Subtitle writing begins → transcript extraction phase.
                if !_firedMilestones.contains(.extractingTranscript),
                   line.contains("Writing subtitles") ||
                   (line.hasPrefix("[download]") && line.contains(".srt")) {
                    _firedMilestones.insert(.extractingTranscript)
                    triggered.append(.extractingTranscript)
                }
            }
            _lock.unlock()
            return triggered
        }

        func makeResult(exitCode: Int32, timedOut: Bool, timeoutSeconds: Double) -> SenseRunResult {
            _lock.lock(); defer { _lock.unlock() }
            let stderrText = String(data: _stderrData, encoding: .utf8) ?? ""
            if timedOut {
                return SenseRunResult(
                    exitCode: -2,
                    stdoutData: _stdoutData,
                    stderrText: "yt-dlp timed out after \(Int(timeoutSeconds))s"
                )
            }
            return SenseRunResult(exitCode: exitCode, stdoutData: _stdoutData, stderrText: stderrText)
        }
    }

    private static func runSenseProcess(
        config: SenseConfig,
        args: [String],
        milestoneCallback: (@Sendable (SenseMilestone) -> Void)? = nil
    ) async -> SenseRunResult {
        let process = Process()
        process.executableURL       = config.ytDlpPath
        process.arguments           = args
        process.currentDirectoryURL = config.outputDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        // Accumulates pipe output arriving on GCD readability-handler threads.
        // Must be set up before process.run() so no bytes are missed.
        let pipeState = SensePipeState()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { pipeState.appendStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            pipeState.appendStderr(data)
            if let cb = milestoneCallback, let text = String(data: data, encoding: .utf8) {
                for milestone in pipeState.checkMilestones(in: text) {
                    cb(milestone)
                }
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return SenseRunResult(exitCode: -1, stdoutData: Data(), stderrText: error.localizedDescription)
        }

        let boxed = SendableProcess(process)

        // Race the process against a hard timeout.
        // withTaskCancellationHandler ensures the subprocess is SIGTERM'd if the
        // timeout branch wins and cancels the process-wait task.
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            boxed.value.waitUntilExit()
                            cont.resume()
                        }
                    }
                } onCancel: {
                    boxed.value.terminate()
                    // Escalate to SIGKILL to avoid hung subprocess trees on Linux CI.
                    _ = kill(boxed.value.processIdentifier, SIGKILL)
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(config.timeoutSeconds * 1_000_000_000))
                return true
            }

            let first = await group.next()!
            group.cancelAll()
            if first {
                // Timeout fired: wait for the process-wait task to drain so that
                // file descriptors are fully closed before we nil the handlers.
                _ = await group.next()
            }
            return first
        }

        // Nil both handlers before the final drain so no handler fires after we read.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Capture any bytes that arrived between the last handler fire and pipe close.
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty { pipeState.appendStdout(remainingStdout) }
        if !remainingStderr.isEmpty { pipeState.appendStderr(remainingStderr) }

        return pipeState.makeResult(
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            timeoutSeconds: config.timeoutSeconds
        )
    }
}

// MARK: - yt-dlp JSON parsing

extension VideoSenser {

    /// Minimal representation of the fields we need from yt-dlp's info dict.
    private struct YtDlpInfo: Decodable {
        let title:               String?
        let uploader:            String?
        let channel:             String?
        let duration:            Double?
        let upload_date:         String?        // "YYYYMMDD"
        let description:         String?
        let tags:                [String]?
        let view_count:          Int?
        let like_count:          Int?
        let comment_count:       Int?
        let extractor_key:       String?
        let webpage_url:         String?
        let chapters:            [YtDlpChapter]?
        /// Manual subtitle tracks keyed by language code (e.g. "en").
        let subtitles:           [String: [SubtitleEntry]]?
        /// Auto-generated subtitle tracks keyed by language code.
        let automatic_captions:  [String: [SubtitleEntry]]?
    }

    private struct YtDlpChapter: Decodable {
        let title:      String?
        let start_time: Double?
    }

    /// Minimal subtitle entry — only `ext` is needed; all other fields are ignored.
    private struct SubtitleEntry: Decodable {
        let ext: String?
    }

    private func parseInfoDict(_ data: Data) -> YtDlpInfo? {
        // --dump-json outputs one JSON object per line; we take the first non-empty line
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineData = Data(line.utf8)
            if let info = try? JSONDecoder().decode(YtDlpInfo.self, from: lineData) {
                return info
            }
        }
        return nil
    }

    private func buildSenseResult(
        url: String,
        info: YtDlpInfo,
        transcriptPath: String?,
        transcriptLanguage: String?,
        fromLocalVault: Bool = false
    ) -> SenseResult {
        let title    = info.title ?? URL(string: url)?.host ?? url
        let uploader = info.uploader ?? info.channel
        let duration = info.duration.map { Int($0.rounded()) }
        let platform = info.extractor_key.map { LibraryPath.displayName(forExtractorFolder: $0) }

        // Convert "YYYYMMDD" → "YYYY-MM-DD"
        let uploadDate: String?
        if let raw = info.upload_date, raw.count == 8 {
            let y = raw.prefix(4)
            let m = raw.dropFirst(4).prefix(2)
            let d = raw.dropFirst(6).prefix(2)
            uploadDate = "\(y)-\(m)-\(d)"
        } else {
            uploadDate = nil
        }

        // Full description — vvx imposes no length cap.
        // descriptionTruncated = false because we cannot detect platform-side truncation.
        let description = info.description.flatMap { $0.isEmpty ? nil : $0 }

        // Determine transcript source from yt-dlp's subtitle / automatic_captions dicts.
        // Manual subtitles take precedence over auto-generated ones (§3.2 of schema spec).
        var transcriptSource: TranscriptSource
        if transcriptPath == nil {
            transcriptSource = .none
        } else if let lang = transcriptLanguage {
            let prefix      = String(lang.prefix(2))
            let hasManual   = info.subtitles?.keys.contains(where: { $0.hasPrefix(prefix) }) ?? false
            let hasAuto     = info.automatic_captions?.keys.contains(where: { $0.hasPrefix(prefix) }) ?? false
            if hasManual {
                transcriptSource = .manual
            } else if hasAuto {
                transcriptSource = .auto
            } else {
                transcriptSource = .unknown
            }
        } else {
            transcriptSource = .unknown
        }

        // Parse SRT into structured blocks.
        let srtBlocks: [SRTBlock]
        if let path = transcriptPath,
           let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            srtBlocks = SRTParser.parse(raw)
        } else {
            srtBlocks = []
        }

        if fromLocalVault {
            if transcriptPath != nil, !srtBlocks.isEmpty {
                transcriptSource = .local
            } else {
                transcriptSource = .none
            }
        }

        // Ordered raw chapters from yt-dlp (already ordered, but sort for safety).
        let rawChapters: [(title: String, startTime: Double)] = (info.chapters ?? [])
            .compactMap { ch in
                guard let t = ch.title, let s = ch.start_time else { return nil }
                return (t, s)
            }
            .sorted { $0.startTime < $1.startTime }

        // Assign each block to a chapter by finding the latest chapter that started
        // at or before the block's start time. nil = block precedes all chapter markers.
        let transcriptBlocks: [TranscriptBlock] = srtBlocks.map { block in
            let wordCount       = block.text.split { $0.isWhitespace }.count
            let estimatedTokens = Int((Double(wordCount) * 1.3).rounded())
            var bestChapter: Int? = nil
            for (i, ch) in rawChapters.enumerated() {
                if ch.startTime <= block.startSeconds { bestChapter = i } else { break }
            }
            return TranscriptBlock(
                index:           block.index,
                startSeconds:    block.startSeconds,
                endSeconds:      block.endSeconds,
                text:            block.text,
                wordCount:       wordCount,
                estimatedTokens: estimatedTokens,
                chapterIndex:    bestChapter
            )
        }

        // Top-level estimatedTokens = sum of block tokens (parity rule §3.6.1).
        // nil when there are no blocks (no transcript).
        let estimatedTokens: Int? = transcriptBlocks.isEmpty
            ? nil
            : transcriptBlocks.map(\.estimatedTokens).reduce(0, +)

        // Build VideoChapter array with endTime and per-chapter token sums.
        let durationDouble = duration.map { Double($0) }
        let chapters: [VideoChapter] = rawChapters.enumerated().map { (i, ch) in
            let endTime: Double? = i + 1 < rawChapters.count
                ? rawChapters[i + 1].startTime
                : durationDouble
            let chapterTokenSum = transcriptBlocks
                .filter { $0.chapterIndex == i }
                .map(\.estimatedTokens)
                .reduce(0, +)
            return VideoChapter(
                title:           ch.title,
                startTime:       ch.startTime,
                endTime:         endTime,
                estimatedTokens: transcriptBlocks.isEmpty ? nil : (chapterTokenSum == 0 ? nil : chapterTokenSum)
            )
        }

        return SenseResult(
            url:                  url,
            title:                VideoTitleSanitizer.clean(title),
            platform:             platform,
            uploader:             uploader,
            durationSeconds:      duration,
            uploadDate:           uploadDate,
            description:          description,
            descriptionTruncated: false,
            tags:                 info.tags ?? [],
            viewCount:            info.view_count,
            likeCount:            info.like_count,
            commentCount:         info.comment_count,
            transcriptPath:       transcriptPath,
            transcriptLanguage:   transcriptLanguage,
            transcriptSource:     transcriptSource,
            transcriptBlocks:     transcriptBlocks,
            estimatedTokens:      estimatedTokens,
            chapters:             chapters
        )
    }
}

// MARK: - Vault subtitle fallback (local-first)

extension VideoSenser {

    /// When sense output has no `.srt`, look under configured archive roots for a
    /// `*.info.json` whose `webpage_url` matches this video, then use the folder’s `.srt`.
    private func findLocalVaultSubtitle(
        canonicalURL: String,
        info: YtDlpInfo
    ) -> (path: String, lang: String)? {
        var candidates: [String] = [canonicalURL]
        if let w = info.webpage_url?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty {
            candidates.append(w)
        }
        let fm = FileManager.default
        for root in Self.archiveSearchRoots() {
            guard fm.fileExists(atPath: root.path) else { continue }
            for infoJSON in Self.collectVaultInfoJSONURLs(in: root) {
                guard let sidecarURL = Self.parseVaultWebpageURL(at: infoJSON),
                      !sidecarURL.isEmpty else { continue }
                guard candidates.contains(where: { Self.urlsMatchForVault($0, sidecarURL) }) else { continue }
                let folder = infoJSON.deletingLastPathComponent()
                guard let path = Self.findPreferredSRT(in: folder) else { continue }
                return (path, Self.subtitleLanguageCode(fromSRTFilename: path))
            }
        }
        return nil
    }

    private static func archiveSearchRoots() -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        let configRoot = VvxConfig.load().resolvedArchiveDirectory()
        let cPath = (configRoot.path as NSString).standardizingPath
        roots.append(configRoot)
        seen.insert(cPath)
        if let movies = MediaStoragePaths.archiveRoot() {
            let mPath = (movies.path as NSString).standardizingPath
            if !seen.contains(mPath) {
                roots.append(movies)
                seen.insert(mPath)
            }
        }
        return roots
    }

    private struct VaultInfoWebURL: Decodable {
        let webpage_url: String?
    }

    private static func collectVaultInfoJSONURLs(in directory: URL) -> [URL] {
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

    private static func parseVaultWebpageURL(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(VaultInfoWebURL.self, from: data))?.webpage_url
    }

    /// Prefers `.en.srt`, then `.en-orig.srt`, then any `.srt` (parity with `VortexIndexer.findSRT`).
    private static func findPreferredSRT(in folder: URL) -> String? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) else { return nil }
        let srts = items.filter { $0.pathExtension.lowercased() == "srt" }
        if let en     = srts.first(where: { $0.lastPathComponent.contains(".en.") })      { return en.path }
        if let enOrig = srts.first(where: { $0.lastPathComponent.contains(".en-orig.") }) { return enOrig.path }
        return srts.first?.path
    }

    private static func subtitleLanguageCode(fromSRTFilename path: String) -> String {
        let lastComp = URL(fileURLWithPath: path).lastPathComponent
        let parts    = lastComp.components(separatedBy: ".")
        return parts.count >= 3 ? parts[parts.count - 2] : "en"
    }

    private static func urlsMatchForVault(_ a: String, _ b: String) -> Bool {
        let ta = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let tb = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if ta.caseInsensitiveCompare(tb) == .orderedSame { return true }
        if let ia = youtubeVideoId(from: ta), let ib = youtubeVideoId(from: tb), ia == ib { return true }
        return false
    }

    private static func youtubeVideoId(from urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        if host.contains("youtu.be") {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        if host.contains("youtube.com") {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "v" })?
                .value
        }
        return nil
    }
}

// MARK: - SRT file discovery

extension VideoSenser {

    /// Scans the output directory for the most relevant .srt file for this video.
    /// Returns (path, languageCode) or (nil, nil) if no transcript was written.
    private func findSRTFile(
        in outputDirectory: URL,
        info: YtDlpInfo
    ) -> (String?, String?) {
        // Walk the output directory looking for .srt files
        guard let enumerator = FileManager.default.enumerator(
            at: outputDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return (nil, nil) }

        var candidates: [(url: URL, lang: String, date: Date)] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "srt" else { continue }
            let lastComp = fileURL.lastPathComponent
            // Language code is the second-to-last extension, e.g. "title.en.srt"
            let parts = lastComp.components(separatedBy: ".")
            let lang  = parts.count >= 3 ? parts[parts.count - 2] : "en"
            let date  = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append((fileURL, lang, date))
        }

        guard !candidates.isEmpty else { return (nil, nil) }

        // Prefer English, then most recently modified
        let sorted = candidates.sorted { a, b in
            let aIsEn = a.lang.hasPrefix("en")
            let bIsEn = b.lang.hasPrefix("en")
            if aIsEn != bIsEn { return aIsEn }
            return a.date > b.date
        }

        let best = sorted[0]
        return (best.url.path, best.lang)
    }

    // MARK: - Extractor error detection

    /// Returns true when yt-dlp stderr suggests the extractor is stale or broken.
    static func looksLikeExtractorError(_ stderr: String) -> Bool {
        let signals = [
            "ExtractorError", "Unsupported URL", "Unable to extract",
            "Sign in to confirm", "This video is unavailable",
            "ERROR: [youtube]", "nsig extraction failed",
        ]
        return signals.contains { stderr.contains($0) }
    }

    static var guidedUpdateMessage: String {
        """

        yt-dlp failed with an extractor error. YouTube may have updated its systems.
        Update your extractor and retry:

          macOS (Homebrew):  brew upgrade yt-dlp
          All platforms:     pip install -U yt-dlp

        """
    }
}
