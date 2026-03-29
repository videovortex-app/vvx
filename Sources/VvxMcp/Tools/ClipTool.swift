import Foundation
import VideoVortexCore

/// MCP implementation of the `clip` tool.
///
/// Extracts a precise video segment as an MP4 file.
/// Mirrors ClipCommand behavior: frame-accurate re-encode by default; --fast for
/// keyframe seek + stream copy. Headless: no interactive ffmpeg prompts.
/// Output path defaults to a smart timestamp-named file in the same directory as input.
enum ClipTool {

    static func call(arguments: [String: Any]) async throws -> String {
        guard let inputPath = arguments["inputPath"] as? String, !inputPath.isEmpty else {
            throw McpToolError.missingArgument("inputPath")
        }
        guard let startStr = arguments["start"] as? String, !startStr.isEmpty else {
            throw McpToolError.missingArgument("start")
        }
        guard let endStr = arguments["end"] as? String, !endStr.isEmpty else {
            throw McpToolError.missingArgument("end")
        }

        let fast       = arguments["fast"]   as? Bool   ?? false
        let outputPath = arguments["output"] as? String

        // Parse times.
        guard let startSec = TimeParser.parseToSeconds(startStr) else {
            let err = VvxError(code: .parseError,
                               message: "Cannot parse start time '\(startStr)'. Accepted: 1:30, 01:14:32, 90, 1m30s.")
            return VvxErrorEnvelope(error: err).jsonString()
        }
        guard let endSec = TimeParser.parseToSeconds(endStr) else {
            let err = VvxError(code: .parseError,
                               message: "Cannot parse end time '\(endStr)'. Accepted: 1:30, 01:14:32, 90, 1m30s.")
            return VvxErrorEnvelope(error: err).jsonString()
        }
        guard endSec > startSec else {
            let err = VvxError(code: .invalidTimeRange,
                               message: "End time (\(TimeParser.formatHHMMSS(endSec))) must be after start time (\(TimeParser.formatHHMMSS(startSec))).")
            return VvxErrorEnvelope(error: err).jsonString()
        }

        // Resolve paths.
        let resolvedInput = resolvePath(inputPath)
        guard FileManager.default.fileExists(atPath: resolvedInput) else {
            let err = VvxError(code: .parseError,
                               message: "Input file not found: \(resolvedInput)")
            return VvxErrorEnvelope(error: err).jsonString()
        }

        let resolver = EngineResolver.cliResolver
        guard let ffmpegURL = resolver.resolvedFfmpegURL() else {
            let err = VvxError(code: .ffmpegNotFound,
                               message: "ffmpeg is required for clip extraction.")
            return VvxErrorEnvelope(error: err).jsonString()
        }

        let resolvedOutput = outputPath.map { resolvePath($0) }
            ?? smartOutputPath(inputPath: resolvedInput, startSec: startSec, endSec: endSec)

        do {
            let result = try await FFmpegRunner.clip(
                ffmpegPath: ffmpegURL,
                inputPath:  resolvedInput,
                start:      startSec,
                end:        endSec,
                outputPath: resolvedOutput,
                fast:       fast
            )
            return buildSuccessJSON(result)

        } catch let error as FFmpegRunner.ClipError {
            let vvxErr: VvxError
            switch error {
            case .ffmpegFailed(let code, let stderrText):
                vvxErr = VvxError(code: .unknownError,
                                  message: "ffmpeg failed (exit \(code)).",
                                  detail: stderrText)
            case .inputNotFound(let path):
                vvxErr = VvxError(code: .parseError,
                                  message: "Input file not found: \(path)")
            case .outputRenameFailed:
                vvxErr = VvxError(code: .permissionDenied,
                                  message: "Could not write output file to \(resolvedOutput).")
            }
            return VvxErrorEnvelope(error: vvxErr).jsonString()
        }
    }

    // MARK: - Helpers

    private static func smartOutputPath(inputPath: String, startSec: Double, endSec: Double) -> String {
        let inputURL  = URL(fileURLWithPath: inputPath)
        let directory = inputURL.deletingLastPathComponent()
        let stem      = inputURL.deletingPathExtension().lastPathComponent
        let ext       = inputURL.pathExtension.isEmpty ? "mp4" : inputURL.pathExtension
        let safeStem  = VideoTitleSanitizer.clean(stem, maxLength: 80)
            .replacingOccurrences(of: " ", with: "_")
        let startTag  = TimeParser.formatCompact(startSec)
        let endTag    = TimeParser.formatCompact(endSec)
        let name      = "\(safeStem)_\(startTag)_to_\(endTag).\(ext)"
        return directory.appendingPathComponent(name).path
    }

    private static func resolvePath(_ raw: String) -> String {
        let expanded = NSString(string: raw).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func buildSuccessJSON(_ result: ClipResult) -> String {
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

        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
        ), let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
