import Foundation
import Logging
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs yt-dlp as a managed child process for a single `DownloadJobConfig`.
///
/// Returns an `AsyncStream<DownloadProgress>` that emits events from first byte to completion.
/// The stream always ends with either `.completed(VideoMetadata)` or `.failed(VvxError)`.
///
/// Consumers:
///   - CLI:      `for await event in downloader.download(config:) { ... }`
///   - Server:   stores active downloads by taskId, streams to `/status/{taskId}`
///   - macOS app: `@Observable` adapter subscribes and maps to `DownloadTask` properties
///
/// No `@MainActor`, no `@Observable`, no SwiftData — purely portable.
public final class VideoDownloader: Sendable {

    private let logger = Logger(label: "com.videovortex.core.VideoDownloader")
    private let thumbnailCacheDirectory: URL

    public init(thumbnailCacheDirectory: URL) {
        self.thumbnailCacheDirectory = thumbnailCacheDirectory
    }

    // MARK: - yt-dlp output templates (identical to app)

    private static let outputTemplateQuick =
        "%(extractor_key)s/%(uploader,channel,NA)s/%(upload_date>%Y-%m-%d,>NoDate)s - %(uploader,channel,NA)s - %(title).70B.%(ext)s"

    private static let outputTemplateArchive =
        "%(extractor_key)s/%(uploader,channel,NA)s/%(upload_date>%Y-%m-%d,>NoDate)s - %(title).75B/%(title).75B.%(ext)s"

    /// Single file in the output directory root (human quick download / `vvx dl`).
    private static let outputTemplateFlat = "%(title).100B.%(ext)s"

    // MARK: - yt-dlp process run result

    private struct YtDlpRunResult: Sendable {
        let exitCode: Int32
        var resolvedOutputPath: String?
        var rawExtractorTitle: String?
        var resolution: String?
        var stderrText: String

        init(exitCode: Int32,
             resolvedOutputPath: String? = nil,
             rawExtractorTitle: String? = nil,
             resolution: String? = nil,
             stderrText: String = "") {
            self.exitCode            = exitCode
            self.resolvedOutputPath  = resolvedOutputPath
            self.rawExtractorTitle   = rawExtractorTitle
            self.resolution          = resolution
            self.stderrText          = stderrText
        }
    }

    // MARK: - Thread-safe accumulator for readabilityHandler state
    //
    // readabilityHandler fires on a private GCD thread. Under Swift 6 strict
    // concurrency, mutating outer `var`s captured from an async frame is a data
    // race. This small class serialises all mutations behind an NSLock and is
    // marked @unchecked Sendable so the closure only ever captures a single `let`.
    private final class ProcessOutputState: @unchecked Sendable {
        private let _lock                      = NSLock()
        private var _resolvedOutputPath: String?
        private var _hasFinalPath              = false   // set to true when [Merger] wins
        private var _rawExtractorTitle:  String?
        private var _resolution:         String?

        // Known video containers that yt-dlp produces as final output.
        private static let videoExtensions: Set<String> = ["mp4", "webm", "mkv", "mov", "m4v", "ts"]

        // Sidecar extensions that should never be treated as the final video path.
        private static let sidecarExtensions: Set<String> = [
            "srt", "vtt", "ass", "ssa", "sub",
            "json", "description", "info",
            "jpg", "jpeg", "png", "webp",
        ]

        /// Called for `[Merger] Merging formats into "..."` — this is always the
        /// definitive final output. Once set, no subsequent `Destination:` line can overwrite it.
        func setFinalPath(_ path: String) {
            _lock.lock(); defer { _lock.unlock() }
            _resolvedOutputPath = path
            _hasFinalPath = true
        }

        /// Returns true if `path` looks like a yt-dlp temporary format fragment
        /// (e.g. `video.f137.mp4`, `audio.f251.webm`).  These are intermediate
        /// streams that get muxed into the final file and then deleted — we never
        /// want to store them as the resolved output path.
        private static func isFragmentPath(_ path: String) -> Bool {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            // yt-dlp names fragments  <title>.f<digits>  before the final extension
            return name.range(of: #"\.f\d+$"#, options: .regularExpression) != nil
        }

        /// Called for every `[download] Destination:` and `[ExtractAudio] Destination:` line.
        /// Ignored when:
        ///   - A `[Merger]` final path has already been stored (_hasFinalPath == true).
        ///   - The extension is a known sidecar (subtitle, thumbnail, metadata).
        ///   - The filename matches the yt-dlp fragment pattern (`.f123.ext`).
        /// Accepted when:
        ///   - No final path yet, and the extension is a known video type.
        ///   - No final path yet and no video candidate yet (fallback: accept anything non-sidecar
        ///     so that single-stream downloads without a Merger line still resolve).
        @discardableResult
        func setVideoPathIfBetter(_ path: String) -> Bool {
            _lock.lock(); defer { _lock.unlock() }
            guard !_hasFinalPath else { return false }
            guard !ProcessOutputState.isFragmentPath(path) else { return false }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            guard !ProcessOutputState.sidecarExtensions.contains(ext) else { return false }
            // Prefer video extension; allow unknown/empty extension as last-resort fallback
            // so single-stream downloads (no Merger line) still get a path.
            if ProcessOutputState.videoExtensions.contains(ext) || _resolvedOutputPath == nil {
                _resolvedOutputPath = path
                return true
            }
            return false
        }

        /// Stores the title only on first call. Returns `true` when it was stored,
        /// `false` when a title was already present (caller skips `.titleResolved`).
        func setTitleIfNil(_ title: String) -> Bool {
            _lock.lock(); defer { _lock.unlock() }
            guard _rawExtractorTitle == nil else { return false }
            _rawExtractorTitle = title
            return true
        }

        /// Stores the resolution only on first call. Returns `true` when stored.
        func setResolutionIfNil(_ res: String) -> Bool {
            _lock.lock(); defer { _lock.unlock() }
            guard _resolution == nil else { return false }
            _resolution = res
            return true
        }

        // Accumulated stderr text for error reporting after process exits.
        private var _stderrChunks: [String] = []

        func appendStderr(_ text: String) {
            _lock.lock(); defer { _lock.unlock() }
            _stderrChunks.append(text)
        }

        func makeResult(exitCode: Int32) -> YtDlpRunResult {
            _lock.lock(); defer { _lock.unlock() }
            return YtDlpRunResult(
                exitCode:           exitCode,
                resolvedOutputPath: _resolvedOutputPath,
                rawExtractorTitle:  _rawExtractorTitle,
                resolution:         _resolution,
                stderrText:         _stderrChunks.joined()
            )
        }
    }

    // MARK: - Public API

    /// Starts a download and returns an async stream of progress events.
    /// The stream is finite — it always ends with `.completed` or `.failed`.
    /// On yt-dlp failure, automatically checks for and installs a newer yt-dlp
    /// version, then retries exactly once before reporting failure.
    public func download(config: DownloadJobConfig) -> AsyncStream<DownloadProgress> {
        let (stream, continuation) = AsyncStream<DownloadProgress>.makeStream()
        let taskId = UUID()
        let log = logger

        Task.detached(priority: .userInitiated) { [thumbnailCacheDirectory] in
            continuation.yield(.preparing)

            do {
                try FileManager.default.createDirectory(
                    at: config.outputDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                continuation.yield(.failed(VvxError(
                    code: .permissionDenied,
                    message: "Could not create output directory: \(error.localizedDescription)",
                    url: config.url
                )))
                continuation.finish()
                return
            }

            let args = Self.buildArguments(config: config)

            var run = await Self.runYtDlpProcess(config: config, args: args, continuation: continuation)

            if run.exitCode == -1 {
                continuation.yield(.failed(VvxError(
                    code: .unknownError,
                    message: "Process launch failed: \(run.stderrText)",
                    url: config.url,
                    detail: run.stderrText
                )))
                continuation.finish()
                return
            }

            var rateIdx = 0
            while run.exitCode != 0 && YtDlpRateLimit.isProbablyRateLimited(run.stderrText)
                && rateIdx < YtDlpRateLimit.backoffSecondsBeforeRetry.count {
                YtDlpRateLimit.printBackoffNotice(attemptIndex: rateIdx)
                let delay = YtDlpRateLimit.backoffSecondsBeforeRetry[rateIdx]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                rateIdx += 1
                run = await Self.runYtDlpProcess(config: config, args: args, continuation: continuation)
            }

            if run.exitCode != 0 {
                // Emit a guided upgrade hint when the failure looks like a stale extractor.
                if Self.looksLikeExtractorError(run.stderrText) {
                    fputs(Self.guidedUpdateMessage, stderr)
                }
                continuation.yield(.failed(VvxError.fromYtDlpStderr(run.stderrText, url: config.url)))
                continuation.finish()
                return
            }

            guard let resolved = run.resolvedOutputPath else {
                continuation.yield(.failed(VvxError(
                    code: .unknownError,
                    message: "Could not resolve output file path from yt-dlp output.",
                    url: config.url
                )))
                continuation.finish()
                return
            }

            // Post-process on the same detached task (already off the main actor).
            do {
                var metadata = try await DownloadCompletionPostProcessor.process(
                    resolvedPath: resolved,
                    rawExtractorTitle: run.rawExtractorTitle,
                    outputDirectory: config.outputDirectory,
                    taskId: taskId,
                    downloadFormat: config.format,
                    originalURL: config.url,
                    thumbnailCacheDirectory: thumbnailCacheDirectory
                )
                if metadata.resolution == nil, let res = run.resolution {
                    metadata.resolution = res
                }
                if config.indexInDatabase {
                    // Await indexing inline (same outer task) so the SQLite write completes
                    // before the CLI process exits.  Errors are logged but do not fail the
                    // download — the media file is already on disk regardless.
                    do {
                        let db = try VortexDB.open()
                        try await VortexIndexer.index(metadata: metadata, db: db)
                    } catch {
                        log.error("VideoDownloader: indexing failed — \(error)")
                    }
                }
                continuation.yield(.completed(metadata))
            } catch {
                log.error("VideoDownloader: post-process failed: \(error.localizedDescription)")
                continuation.yield(.failed(VvxError(
                    code: .unknownError,
                    message: error.localizedDescription,
                    url: config.url
                )))
            }

            continuation.finish()
        }

        return stream
    }

    // MARK: - Argument builder

    private static func buildArguments(config: DownloadJobConfig) -> [String] {
        var args: [String] = []
        if let ffmpeg = config.ffmpegPath {
            args.append(contentsOf: ["--ffmpeg-location", ffmpeg.path])
        }
        args.append(contentsOf: config.format.ytDlpArguments(
            isArchiveMode: config.isArchiveMode,
            allSubtitleLanguages: config.allSubtitleLanguages
        ))
        if let browser = config.browserCookies {
            args.append(contentsOf: ["--cookies-from-browser", browser])
        }
        if config.removeSponsorSegments {
            args.append(contentsOf: ["--sponsorblock-remove", "sponsor"])
        }
        if config.requestHumanLikePacing {
            args.append(contentsOf: ["--sleep-requests", "1", "--sleep-interval", "2"])
        }
        let outputTemplate: String
        if config.useFlatOutputTemplate {
            outputTemplate = outputTemplateFlat
        } else if config.isArchiveMode {
            outputTemplate = outputTemplateArchive
        } else {
            outputTemplate = outputTemplateQuick
        }
        args.append(contentsOf: [
            "-o", outputTemplate,
            // Stable API for the final output path (avoids fragile parsing of [Merger]/Destination lines).
            // Prints a single raw filepath line after the file has been moved into place.
            "--print", "after_move:filepath",
            "--trim-filenames", "250",
            "--no-mtime",
            "--newline",
            "--no-color",
            "--progress",
            config.url,
        ])
        return args
    }

    // MARK: - Process runner (shared between first attempt and retry)

    private static func runYtDlpProcess(
        config: DownloadJobConfig,
        args: [String],
        continuation: AsyncStream<DownloadProgress>.Continuation
    ) async -> YtDlpRunResult {
        let process = Process()
        process.executableURL       = config.ytDlpPath
        process.arguments           = args
        process.currentDirectoryURL = config.outputDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        // All mutable state lives inside this lock-protected object so the
        // readabilityHandler closure captures only a single `let` reference,
        // satisfying Swift 6 Sendable requirements.
        let state = ProcessOutputState()

        // Shared closure: parse a single yt-dlp output line for path / progress / title.
        // Called from both stdout and stderr readabilityHandlers so [Merger] and
        // [download] Destination: lines are captured regardless of which stream
        // yt-dlp writes them to (varies by version and flags).
        let parseLine: @Sendable (String) -> Void = { line in
            let parsed = YtDlpOutputParser.parse(line, currentFormat: config.format)
            switch parsed {
            case .mergerOutputPath(let p):
                state.setFinalPath(p)
                let stem = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
                if !stem.isEmpty { continuation.yield(.titleResolved(stem)) }

            case .printedFilepath(let p):
                // `--print after_move:filepath` emits the final path as a raw absolute filepath line.
                // Treat it as definitive final output.
                state.setFinalPath(p)
                let stem = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
                if !stem.isEmpty { continuation.yield(.titleResolved(stem)) }

            case .extractAudioDestination(let p), .destinationPath(let p):
                if state.setVideoPathIfBetter(p) {
                    let stem = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
                    if !stem.isEmpty { continuation.yield(.titleResolved(stem)) }
                }
            case .progress(let pct, let speed, let eta):
                continuation.yield(.downloading(percent: pct, speed: speed, eta: eta))
            case .extractorTitle(let title):
                if state.setTitleIfNil(title) {
                    continuation.yield(.titleResolved(title))
                }
            case .resolution(let res):
                if state.setResolutionIfNil(res) {
                    continuation.yield(.resolutionResolved(res))
                }
            case .unknown:
                break
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                parseLine(line)
            }
        }

        // Parse stderr in real time so [Merger] / [download] Destination: lines
        // that yt-dlp sends to stderr (common with --progress --newline) are not lost.
        // Raw text is also accumulated for error reporting on non-zero exit.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            state.appendStderr(text)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                parseLine(line)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return YtDlpRunResult(exitCode: -1, stderrText: error.localizedDescription)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                cont.resume()
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Drain any data that was buffered in the pipes but not yet delivered
        // to the readabilityHandlers before waitUntilExit() returned.
        // The [Merger] line is almost always the very last thing yt-dlp writes,
        // so it routinely ends up here rather than in the async handler callbacks.
        let drainStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !drainStdout.isEmpty, let text = String(data: drainStdout, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                parseLine(line)
            }
        }
        let drainStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !drainStderr.isEmpty, let text = String(data: drainStderr, encoding: .utf8) {
            state.appendStderr(text)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                parseLine(line)
            }
        }

        return state.makeResult(exitCode: process.terminationStatus)
    }
}

// MARK: - URL canonicalization (shared across CLI, server, and app)

extension VideoDownloader {
    /// Normalizes a URL for duplicate checking (twitter→x.com, trailing slash, lowercase host).
    public static func canonicalURL(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        if let scheme = components.scheme { components.scheme = scheme.lowercased() }
        if let host = components.host {
            var h = host.lowercased()
            if h.hasPrefix("www.") { h.removeFirst(4) }
            if h == "twitter.com" || h == "mobile.twitter.com" { h = "x.com" }
            components.host = h
        }
        var path = components.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
            components.path = path
        }
        return components.string ?? trimmed
    }

    // MARK: - Extractor error detection

    /// Returns true when yt-dlp stderr suggests the extractor is stale or broken.
    /// Used to emit a guided update hint without attempting an auto-upgrade.
    static func looksLikeExtractorError(_ stderr: String) -> Bool {
        let signals = [
            "ExtractorError", "Unsupported URL", "Unable to extract",
            "Sign in to confirm", "This video is unavailable",
            "ERROR: [youtube]", "nsig extraction failed",
        ]
        return signals.contains { stderr.contains($0) }
    }

    private static var guidedUpdateMessage: String {
        """

        yt-dlp failed with an extractor error. YouTube may have updated its systems.
        Update your extractor and retry:

          macOS (Homebrew):  brew upgrade yt-dlp
          All platforms:     pip install -U yt-dlp

        """
    }

    /// Returns true if `string` looks like a supported video URL.
    public static func isSupportedVideoURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return false }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return h == "youtu.be"
            || h.contains("youtube.com")
            || h.contains("tiktok.com")
            || h == "x.com" || h.hasSuffix(".x.com")
            || h.contains("twitter.com")
            || h.contains("instagram.com")
            || h.contains("vimeo.com")
            || h.contains("twitch.tv")
    }
}
