import Foundation

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
/// Two modes:
///   - **Frame-accurate (default):** `-ss` after `-i`, re-encode. Tries hardware
///     acceleration first (VideoToolbox on macOS), falls back to libx264.
///   - **Fast (`--fast`):** `-ss` before `-i`, stream copy. Instant but ±2-5s keyframe drift.
///
/// All writes are atomic: output goes to a sibling `name.tmp.<ext>` file so ffmpeg
/// still sees a standard extension (muxer); renamed to the final path only on success.
public enum FFmpegRunner {

    public enum ClipError: Error, Sendable {
        case ffmpegFailed(exitCode: Int32, stderr: String)
        case inputNotFound(path: String)
        case outputRenameFailed
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
    ///   - pad:           Handle width in seconds applied via `paddedBounds`. Default `0`.
    ///   - videoDuration: Source video duration for EOF clamp when pad > 0. Default `nil`.
    public static func clip(
        ffmpegPath: URL,
        inputPath: String,
        start: Double,
        end: Double,
        outputPath: String,
        fast: Bool,
        pad: Double = 0,
        videoDuration: Double? = nil
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
                args: fastArgs(input: inputPath, start: actualStart, duration: duration, output: tmpPath)
            )
            try atomicRename(from: tmpPath, to: outputPath)
            return ClipResult(
                inputPath: inputPath, outputPath: outputPath,
                startSeconds: actualStart, endSeconds: actualEnd, durationSeconds: duration,
                method: "copy", completedAt: Date()
            )
        }

        // Frame-accurate: try hardware acceleration, then software fallback.
        #if os(macOS)
        do {
            try await runFFmpeg(
                ffmpegPath: ffmpegPath,
                args: accurateArgs(
                    input: inputPath, start: actualStart, duration: duration,
                    output: tmpPath, encoder: "h264_videotoolbox", extraFlags: ["-b:v", "5M"]
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
                output: tmpPath, encoder: "libx264", extraFlags: ["-preset", "fast"]
            )
        )
        try atomicRename(from: tmpPath, to: outputPath)
        return ClipResult(
            inputPath: inputPath, outputPath: outputPath,
            startSeconds: actualStart, endSeconds: actualEnd, durationSeconds: duration,
            method: "libx264", completedAt: Date()
        )
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

    private static func fastArgs(input: String, start: Double, duration: Double, output: String) -> [String] {
        ["-y", "-nostdin", "-ss", String(start), "-i", input, "-t", String(duration), "-c", "copy", output]
    }

    private static func accurateArgs(
        input: String, start: Double, duration: Double,
        output: String, encoder: String, extraFlags: [String]
    ) -> [String] {
        ["-y", "-nostdin", "-i", input, "-ss", String(start), "-t", String(duration),
         "-c:v", encoder] + extraFlags + ["-c:a", "aac", output]
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
