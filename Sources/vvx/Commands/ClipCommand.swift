import ArgumentParser
import Foundation
import VideoVortexCore

struct ClipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clip",
        abstract: "Extract a precise video segment as an MP4 file.",
        discussion: """
        clip is a stateless ffmpeg wrapper that extracts an exact time range from
        a local video file. Default mode is frame-accurate (re-encode); --fast uses
        keyframe seek + stream copy for instant extraction at the cost of ±2-5s drift.

        The search → clip loop:
          vvx search "quantum computing" --rag   # find the moment
          vvx clip "/vault/video.mp4" --start 00:14:32 --end 00:14:47

        Time formats accepted: 1:30, 01:14:32, 90, 90.5, 1m30s, 2h1m30s

        Examples:
          vvx clip video.mp4 --start 1:30 --end 1:45
          vvx clip video.mp4 --start 00:14:32 --end 00:14:47 --fast
          vvx clip video.mp4 --start 1m30s --duration 15
          vvx clip video.mp4 --start 0:45 --end 1:15 --output ~/Desktop/clip.mp4
          vvx clip video.mp4 --start 12:00 --end 16:30 --open
        """
    )

    @Argument(help: "Path to the source video file.")
    var videoPath: String

    @Option(help: "Start time (e.g. 1:30, 90, 01:14:32, 1m30s).")
    var start: String

    @Option(help: "End time (e.g. 1:45, 105, 01:14:47, 1m45s).")
    var end: String?

    @Option(help: "Duration instead of end time (e.g. 15, 15s, 0:15).")
    var duration: String?

    @Option(help: "Output file path. Default: same directory as input, smart name from timestamps.")
    var output: String?

    @Flag(help: "Fast mode: keyframe seek + stream copy (no re-encode). Instant but ±2-5s drift.")
    var fast: Bool = false

    @Flag(name: .long, help: "Open the clip in the default video player after extraction.")
    var open: Bool = false

    mutating func run() async throws {
        let startSec = guardParse(start, label: "start")
        let endSec   = resolveEndSeconds(startSec: startSec)

        guard endSec > startSec else {
            printClipError(
                code: .parseError,
                message: "End time (\(TimeParser.formatHHMMSS(endSec))) must be after start time (\(TimeParser.formatHHMMSS(startSec)))."
            )
            throw ExitCode.failure
        }

        let resolvedInput = resolvePath(videoPath)
        guard FileManager.default.fileExists(atPath: resolvedInput) else {
            printClipError(
                code: .parseError,
                message: "Input file not found: \(resolvedInput)"
            )
            throw ExitCode.failure
        }

        let resolver = EngineResolver.cliResolver
        guard let ffmpegURL = resolver.resolvedFfmpegURL() else {
            printClipError(
                code: .ffmpegNotFound,
                message: "ffmpeg is required for clip extraction."
            )
            throw ExitCode(VvxExitCode.engineNotFound)
        }

        let resolvedOutput = output.map { resolvePath($0) }
            ?? smartOutputPath(inputPath: resolvedInput, startSec: startSec, endSec: endSec)

        let mode = fast ? "fast (stream copy)" : "frame-accurate"
        fputs("Clipping \(TimeParser.formatHHMMSS(startSec)) → \(TimeParser.formatHHMMSS(endSec)) [\(mode)]...\n", stderr)

        let startTime = Date()

        do {
            let result = try await FFmpegRunner.clip(
                ffmpegPath: ffmpegURL,
                inputPath: resolvedInput,
                start: startSec,
                end: endSec,
                outputPath: resolvedOutput,
                fast: fast
            )

            let elapsed = Date().timeIntervalSince(startTime)
            let display = result.outputPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            fputs("✓ Clip done in \(String(format: "%.1f", elapsed))s → \(display)\n", stderr)

            printClipSuccess(result)

            if open { openFile(at: result.outputPath) }

        } catch let error as FFmpegRunner.ClipError {
            switch error {
            case .ffmpegFailed(let code, let stderrText):
                Foundation.fputs("✗ ffmpeg exited with code \(code)\n", stderr)
                printClipError(
                    code: .unknownError,
                    message: "ffmpeg failed (exit \(code)).",
                    detail: stderrText
                )
                throw ExitCode.failure
            case .inputNotFound(let path):
                printClipError(code: .parseError, message: "Input file not found: \(path)")
                throw ExitCode.failure
            case .outputRenameFailed:
                printClipError(code: .permissionDenied, message: "Could not write output file to \(resolvedOutput).")
                throw ExitCode.failure
            }
        }
    }

    // MARK: - Time resolution

    private func guardParse(_ input: String, label: String) -> Double {
        guard let seconds = TimeParser.parseToSeconds(input) else {
            printClipError(
                code: .parseError,
                message: "Cannot parse \(label) time: \"\(input)\". Accepted formats: 1:30, 01:14:32, 90, 1m30s."
            )
            ClipCommand.exit(withError: ExitCode.failure)
        }
        return seconds
    }

    private func resolveEndSeconds(startSec: Double) -> Double {
        if let endStr = end {
            return guardParse(endStr, label: "end")
        }
        if let durStr = duration {
            let dur = guardParse(durStr, label: "duration")
            return startSec + dur
        }
        printClipError(code: .parseError, message: "Either --end or --duration is required.")
        ClipCommand.exit(withError: ExitCode.failure)
    }

    // MARK: - Smart naming

    private func smartOutputPath(inputPath: String, startSec: Double, endSec: Double) -> String {
        let inputURL   = URL(fileURLWithPath: inputPath)
        let directory  = inputURL.deletingLastPathComponent()
        let stem       = inputURL.deletingPathExtension().lastPathComponent
        let ext        = inputURL.pathExtension.isEmpty ? "mp4" : inputURL.pathExtension

        let safeStem   = VideoTitleSanitizer.clean(stem, maxLength: 80)
            .replacingOccurrences(of: " ", with: "_")
        let startTag   = TimeParser.formatCompact(startSec)
        let endTag     = TimeParser.formatCompact(endSec)
        let name       = "\(safeStem)_\(startTag)_to_\(endTag).\(ext)"

        return directory.appendingPathComponent(name).path
    }

    // MARK: - Path helpers

    private func resolvePath(_ raw: String) -> String {
        let expanded = NSString(string: raw).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    // MARK: - JSON output

    private func printClipSuccess(_ result: ClipResult) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var dict: [String: Any] = [
            "success":         true,
            "inputPath":       result.inputPath,
            "outputPath":      result.outputPath,
            "startTime":       TimeParser.formatHHMMSS(result.startSeconds),
            "endTime":         TimeParser.formatHHMMSS(result.endSeconds),
            "durationSeconds": result.durationSeconds,
            "method":          result.method,
            "completedAt":     iso.string(from: result.completedAt)
        ]

        if let bytes = try? FileManager.default.attributesOfItem(atPath: result.outputPath)[.size] as? Int64 {
            dict["sizeBytes"] = bytes
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
        ), let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    private func printClipError(code: VvxErrorCode, message: String, detail: String? = nil) {
        let error = VvxError(code: code, message: message, detail: detail)
        print(VvxErrorEnvelope(error: error).jsonString())
    }

    // MARK: - Open file

    private func openFile(at path: String) {
        #if os(macOS)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        try? proc.run()
        #else
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        proc.arguments = [path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        try? proc.run()
        #endif
    }
}
