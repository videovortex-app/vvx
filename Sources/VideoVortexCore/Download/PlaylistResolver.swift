import Foundation

// MARK: - PlaylistResolver

/// Extracts individual video URLs from a YouTube channel, playlist, or any yt-dlp
/// supported collection URL, using `--flat-playlist --print webpage_url`.
///
/// **Memory safety:** stdout is read line-by-line via a `readabilityHandler`.
/// URLs are yielded to the stream immediately — the full list is never accumulated
/// in memory, so a 5 000-video channel does not spike resident memory.
///
/// **Early termination:** When `limit` is supplied, `--playlist-items 1-N` tells
/// yt-dlp to stop after N items — sync workers can start before the resolver
/// finishes, and the resolver exits as soon as N URLs are available.
///
/// **Malformed output handling:** Empty lines, `NA` sentinels, and anything that
/// does not start with `https://` are silently skipped.
public struct PlaylistResolver {

    // MARK: - Public API

    /// Returns an `AsyncThrowingStream` that yields one resolved video URL per element.
    ///
    /// - Parameters:
    ///   - url:        The channel / playlist / collection URL to resolve.
    ///   - limit:      Optional upper bound — passed to yt-dlp as `--playlist-items 1-N`.
    ///                 Pass `nil` when `--incremental` is active so yt-dlp streams the full
    ///                 playlist; the Swift consumer breaks once enough new videos are enqueued.
    ///   - matchTitle: If provided, appended as `--match-title <value>` — yt-dlp filters titles.
    ///   - afterDate:  If provided, appended as `--dateafter <value>` — yt-dlp parses natively
    ///                 (accepts YYYYMMDD, "7d", "today", etc.). No validation is applied here.
    ///   - ytDlpPath:  Path to the yt-dlp binary.
    public static func resolve(
        url:        String,
        limit:      Int?,
        matchTitle: String? = nil,
        afterDate:  String? = nil,
        ytDlpPath:  URL
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task.detached {
                // Build yt-dlp arguments.
                // --no-warnings   — suppress non-fatal advisory messages on stderr.
                // --print webpage_url — one URL per line, no additional fields.
                var args: [String] = [
                    "--flat-playlist",
                    "--no-warnings",
                    "--print", "webpage_url"
                ]
                if let limit {
                    args += ["--playlist-items", "1-\(limit)"]
                }
                if let matchTitle {
                    args += ["--match-title", matchTitle]
                }
                if let afterDate {
                    args += ["--dateafter", afterDate]
                }
                args.append(url)

                let process = Process()
                process.executableURL = ytDlpPath
                process.arguments     = args

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError  = stderrPipe

                // Line accumulator — shared between the readabilityHandler GCD thread
                // and the main Task body; internal NSLock provides thread safety.
                let lineBuf = _LineBuffer()

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    for resolved in lineBuf.drain(appending: text) {
                        continuation.yield(resolved)
                    }
                }

                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.finish(throwing: VvxError(
                        code:    .unknownError,
                        message: "Failed to launch yt-dlp for flat-playlist: \(error.localizedDescription)",
                        url:     url
                    ))
                    return
                }

                // Wait for yt-dlp to finish on a background thread so the Swift
                // concurrency runtime is not blocked.
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .utility).async {
                        process.waitUntilExit()
                        cont.resume()
                    }
                }

                // Nil the handler BEFORE the final drain to prevent the handler
                // from racing with `readDataToEndOfFile()`.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil

                // Drain bytes that arrived after the last handler invocation.
                let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !remaining.isEmpty, let text = String(data: remaining, encoding: .utf8) {
                    for resolved in lineBuf.drain(appending: text) {
                        continuation.yield(resolved)
                    }
                }
                // Flush any URL that was still waiting for a trailing newline.
                for resolved in lineBuf.flush() {
                    continuation.yield(resolved)
                }

                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

                // Only fail the stream on non-zero exit when no URLs were produced.
                // A partial playlist (e.g. some private videos) is not a fatal error
                // — individual failures surface as per-URL errors in SyncCommand.
                if process.terminationStatus != 0, lineBuf.totalYielded == 0 {
                    continuation.finish(
                        throwing: VvxError.fromYtDlpStderr(stderrText, url: url)
                    )
                } else {
                    continuation.finish()
                }
            }
        }
    }
}

// MARK: - _LineBuffer (private)

/// Thread-safe rolling line buffer.
///
/// Splits incoming text chunks at `\n`, keeps the last incomplete fragment,
/// and returns validated `https://` URLs from each complete line.
/// `@unchecked Sendable` is safe because all mutable state is protected by `lock`.
private final class _LineBuffer: @unchecked Sendable {

    private let lock  = NSLock()
    private var buf   = ""

    /// Total valid URLs emitted so far (used to distinguish total-failure from
    /// partial-success on yt-dlp non-zero exit).
    private(set) var totalYielded: Int = 0

    /// Appends `text`, splits on `\n`, and returns complete valid URLs.
    func drain(appending text: String) -> [String] {
        lock.lock()
        buf += text
        var parts = buf.components(separatedBy: "\n")
        buf = parts.removeLast()    // keep any incomplete trailing fragment
        lock.unlock()

        let urls = parts.compactMap { validURL(from: $0) }
        if !urls.isEmpty {
            lock.lock()
            totalYielded += urls.count
            lock.unlock()
        }
        return urls
    }

    /// Flushes any remaining content after the process exits (handles streams that
    /// end without a trailing newline).
    func flush() -> [String] {
        lock.lock()
        let remaining = buf
        buf = ""
        lock.unlock()

        guard let u = validURL(from: remaining) else { return [] }
        lock.lock()
        totalYielded += 1
        lock.unlock()
        return [u]
    }

    // MARK: - Validation

    private func validURL(from line: String) -> String? {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s != "NA", s.hasPrefix("https://") else { return nil }
        return s
    }
}
