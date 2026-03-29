import Foundation

/// Metadata to embed in the output MP4 container via standard `-metadata` atoms.
///
/// Injected on the **same** ffmpeg clip invocation — stream copy for A/V streams,
/// no second mux pass. Values are truncated at 250 characters to stay within safe
/// atom limits; the clip is never failed due to metadata issues.
public struct SourceMetadata: Sendable {
    /// Video title embedded as the `title` atom.
    public let title: String?
    /// Uploader or channel name embedded as the `artist` atom.
    public let artist: String?
    /// Short provenance string embedded as the `comment` atom,
    /// e.g. `"Source: https://… | Gathered by vvx"`.
    public let comment: String?

    public init(title: String?, artist: String?, comment: String?) {
        self.title   = title
        self.artist  = artist
        self.comment = comment
    }
}

/// Result of a successful clip extraction.
public struct ClipResult: Sendable {
    public let inputPath: String
    public let outputPath: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let durationSeconds: Double
    /// The encoding method that succeeded: `"videotoolbox"`, `"libx264"`, or `"copy"`.
    public let method: String
    public let completedAt: Date
}

/// Stateless ffmpeg wrapper for frame-accurate and fast clip extraction.
///
/// Three modes (mutually exclusive — callers must enforce):
///   - **Default:** `-ss` after `-i`, re-encode. Tries VideoToolbox on macOS, falls back to libx264.
///   - **Fast (`fast: true`):** `-ss` before `-i`, stream copy. Instant but ±2-5s keyframe drift.
///   - **Exact (`exact: true`):** forces `libx264 -crf 18 -preset fast`, bypassing VideoToolbox.
///     Guarantees constant-quality CRF semantics across all platforms.
///
/// All writes are atomic: output goes to a sibling `name.tmp.<ext>` file so ffmpeg
/// still sees a standard extension (muxer); renamed to the final path only on success.
public enum FFmpegRunner {

    public enum ClipError: Error, Sendable {
        case ffmpegFailed(exitCode: Int32, stderr: String)
        case inputNotFound(path: String)
        case outputRenameFailed
    }

    public enum ThumbnailError: Error, Sendable {
        case ffmpegFailed(exitCode: Int32, stderr: String)
        case inputNotFound(path: String)
    }

    /// Compute padded clip bounds from logical start/end — the **single source of truth** for
    /// `--pad` math used by `clip(...)`, `GatherCommand`, and dry-run planning.
    ///
    /// - Parameters:
    ///   - logicalStart:   Logical clip start in seconds (L0, after snap/context resolution).
    ///   - logicalEnd:     Logical clip end in seconds (L1).
    ///   - pad:            Handle width: seconds subtracted from start and added to end.
    ///   - videoDuration:  Optional video duration for EOF clamp. When `nil`, the end is
    ///                     not clamped (ffmpeg stops at EOF for well-formed containers).
    /// - Returns: `(start, end)` with `start ≥ 0` and `end ≤ videoDuration` when known.
    public static func paddedBounds(
        logicalStart: Double,
        logicalEnd: Double,
        pad: Double,
        videoDuration: Double? = nil
    ) -> (start: Double, end: Double) {
        let start  = max(0, logicalStart - pad)
        let rawEnd = logicalEnd + pad
        let end    = videoDuration.map { min($0, rawEnd) } ?? rawEnd
        return (start, end)
    }

    /// Extract a clip from a local video file.
    ///
    /// - Parameters:
    ///   - ffmpegPath:    Resolved path to the ffmpeg binary (from `EngineResolver`).
    ///   - inputPath:     Absolute path to the source video.
    ///   - start:         Logical start time in seconds (L0).
    ///   - end:           Logical end time in seconds (L1); must be > start.
    ///   - outputPath:    Final destination path for the clip.
    ///   - fast:          When true, uses keyframe seek + stream copy (no re-encode).
    ///   - exact:         When true, forces `libx264 -crf 18`, bypassing VideoToolbox entirely
    ///                    for platform-consistent quality. Mutually exclusive with `fast`.
    ///   - pad:           Handle width in seconds applied via `paddedBounds`. Default `0`.
    ///   - videoDuration: Source video duration for EOF clamp when pad > 0. Default `nil`.
    ///   - metadata:      Optional `SourceMetadata` to embed as MP4 atoms on this same pass.
    public static func clip(
        ffmpegPath: URL,
        inputPath: String,
        start: Double,
        end: Double,
        outputPath: String,
        fast: Bool,
        exact: Bool = false,
        pad: Double = 0,
        videoDuration: Double? = nil,
        metadata: SourceMetadata? = nil
    ) async throws -> ClipResult {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw ClipError.inputNotFound(path: inputPath)
        }

        let (actualStart, actualEnd) = paddedBounds(
            logicalStart: start,
            logicalEnd: end,
            pad: pad,
            videoDuration: videoDuration
        )
        let duration = actualEnd - actualStart
        let tmpPath  = Self.atomicTempPath(forFinalOutput: outputPath)

        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        if fast {
            try await runFFmpeg(
                ffmpegPath: ffmpegPath,
                args: fastArgs(input: inputPath, start: actualStart, duration: duration,
                               output: tmpPath, metadata: metadata)
            )
            try atomicRename(from: tmpPath, to: outputPath)
            return ClipResult(
                inputPath: inputPath, outputPath: outputPath,
                startSeconds: actualStart, endSeconds: actualEnd, durationSeconds: duration,
                method: "copy", completedAt: Date()
            )
        }

        // Exact mode: libx264 CRF 18, platform-consistent quality. Bypass VideoToolbox
        // because h264_videotoolbox uses bitrate (not CRF), breaking the quality promise.
        if exact {
            try await runFFmpeg(
                ffmpegPath: ffmpegPath,
                args: accurateArgs(
                    input: inputPath, start: actualStart, duration: duration,
                    output: tmpPath, encoder: "libx264",
                    extraFlags: ["-crf", "18", "-preset", "fast"],
                    metadata: metadata
                )
            )
            try atomicRename(from: tmpPath, to: outputPath)
            return ClipResult(
                inputPath: inputPath, outputPath: outputPath,
                startSeconds: actualStart, endSeconds: actualEnd, durationSeconds: duration,
                method: "libx264-exact", completedAt: Date()
            )
        }

        // Default: frame-accurate re-encode. Try hardware acceleration, then software fallback.
        #if os(macOS)
        do {
            try await runFFmpeg(
                ffmpegPath: ffmpegPath,
                args: accurateArgs(
                    input: inputPath, start: actualStart, duration: duration,
                    output: tmpPath, encoder: "h264_videotoolbox", extraFlags: ["-b:v", "5M"],
                    metadata: metadata
                )
            )
            try atomicRename(from: tmpPath, to: outputPath)
            return ClipResult(
                inputPath: inputPath, outputPath: outputPath,
                startSeconds: actualStart, endSeconds: actualEnd, durationSeconds: duration,
                method: "videotoolbox", completedAt: Date()
            )
        } catch {
            try? FileManager.default.removeItem(atPath: tmpPath)
        }
        #endif

        try await runFFmpeg(
            ffmpegPath: ffmpegPath,
            args: accurateArgs(
                input: inputPath, start: actualStart, duration: duration,
                output: tmpPath, encoder: "libx264", extraFlags: ["-preset", "fast"],
                metadata: metadata
            )
        )
        try atomicRename(from: tmpPath, to: outputPath)
        return ClipResult(
            inputPath: inputPath, outputPath: outputPath,
            startSeconds: actualStart, endSeconds: actualEnd, durationSeconds: duration,
            method: "libx264", completedAt: Date()
        )
    }

    /// Extract a single JPEG still from a local video at the given timestamp.
    ///
    /// Uses a fast pre-seek so the nearest keyframe is decoded — adequate for thumbnails.
    /// `-q:v 2` produces a high-quality JPEG (1 = best, 31 = worst in ffmpeg's VBR scale).
    /// Failure does **not** affect the clip; callers should treat errors as soft warnings.
    public static func thumbnail(
        ffmpegPath: URL,
        inputPath: String,
        atSeconds: Double,
        outputPath: String
    ) async throws {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw ThumbnailError.inputNotFound(path: inputPath)
        }
        let args: [String] = [
            "-y", "-nostdin",
            "-ss", String(atSeconds),
            "-i", inputPath,
            "-frames:v", "1",
            "-q:v", "2",
            outputPath
        ]
        do {
            try await runFFmpeg(ffmpegPath: ffmpegPath, args: args)
        } catch let err as ClipError {
            switch err {
            case .ffmpegFailed(let code, let stderr):
                throw ThumbnailError.ffmpegFailed(exitCode: code, stderr: stderr)
            default:
                throw ThumbnailError.ffmpegFailed(exitCode: -1, stderr: "\(err)")
            }
        }
    }

    /// `file.mp4.tmp` breaks ffmpeg’s muxer (extension `.tmp`). Use `file.tmp.mp4` instead.
    private static func atomicTempPath(forFinalOutput outputPath: String) -> String {
        let url = URL(fileURLWithPath: outputPath)
        let ext = url.pathExtension
        guard !ext.isEmpty else {
            return outputPath + ".tmp"
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let tmpName = "\(stem).tmp.\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(tmpName).path
    }

    // MARK: - Argument builders

    private static func fastArgs(
        input: String, start: Double, duration: Double,
        output: String, metadata: SourceMetadata? = nil
    ) -> [String] {
        var args = ["-y", "-nostdin", "-ss", String(start), "-i", input,
                    "-t", String(duration), "-c", "copy"]
        if let meta = metadata { args += metadataArgs(for: meta) }
        args.append(output)
        return args
    }

    private static func accurateArgs(
        input: String, start: Double, duration: Double,
        output: String, encoder: String, extraFlags: [String],
        metadata: SourceMetadata? = nil
    ) -> [String] {
        var args = ["-y", "-nostdin", "-i", input, "-ss", String(start),
                    "-t", String(duration), "-c:v", encoder]
                 + extraFlags + ["-c:a", "aac"]
        if let meta = metadata { args += metadataArgs(for: meta) }
        args.append(output)
        return args
    }

    // MARK: - Metadata helpers

    /// Build `-metadata key=value` argument pairs from a `SourceMetadata` value.
    /// Values are truncated at 250 characters with an ellipsis to stay within safe atom limits.
    private static func metadataArgs(for meta: SourceMetadata) -> [String] {
        var args: [String] = []
        if let title = meta.title, !title.isEmpty {
            args += ["-metadata", "title=\(sanitize(title))"]
        }
        if let artist = meta.artist, !artist.isEmpty {
            args += ["-metadata", "artist=\(sanitize(artist))"]
        }
        if let comment = meta.comment, !comment.isEmpty {
            args += ["-metadata", "comment=\(sanitize(comment))"]
        }
        return args
    }

    private static func sanitize(_ value: String, maxLength: Int = 250) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength - 1)) + "…"
    }

    // MARK: - Process execution

    private static func runFFmpeg(ffmpegPath: URL, args: [String]) async throws {
        let process = Process()
        process.executableURL = ffmpegPath
        process.arguments     = args
        // Headless: do not inherit the controlling tty or ffmpeg can stop (state T) on SIGTTIN.
        process.standardInput  = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // Drain stderr continuously as ffmpeg writes it.
        // readabilityHandler fires on a GCD thread whenever bytes are available,
        // preventing the 64 KiB kernel pipe buffer from filling and blocking ffmpeg.
        let accumulator = _StderrAccumulator()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { accumulator.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ClipError.ffmpegFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        let boxed = _SendableProcess(process)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                boxed.value.waitUntilExit()
                cont.resume()
            }
        }

        // Nil the handler before the final drain so no handler fires after we read.
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Capture any bytes that arrived between the last handler fire and pipe close.
        let tail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { accumulator.append(tail) }

        let exitCode = process.terminationStatus
        guard exitCode == 0 else {
            let stderrText = String(data: accumulator.data, encoding: .utf8) ?? ""
            throw ClipError.ffmpegFailed(exitCode: exitCode, stderr: String(stderrText.suffix(500)))
        }
    }

    // MARK: - Atomic rename

    private static func atomicRename(from src: String, to dst: String) throws {
        if FileManager.default.fileExists(atPath: dst) {
            try FileManager.default.removeItem(atPath: dst)
        }
        do {
            try FileManager.default.moveItem(atPath: src, toPath: dst)
        } catch {
            throw ClipError.outputRenameFailed
        }
    }
}

/// Sendable wrapper for Process so it can cross isolation boundaries.
private struct _SendableProcess: @unchecked Sendable {
    let value: Process
    init(_ process: Process) { self.value = process }
}

private final class _StderrAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        _data.append(chunk)
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return _data
    }
}
