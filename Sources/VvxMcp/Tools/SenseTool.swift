import Foundation
import VideoVortexCore

/// MCP implementation of the `sense` tool.
///
/// Returns SenseResult v3 JSON by default, which includes inline `transcriptBlocks`
/// so agents can read video content in a single call.
///
/// Step 10 parity: `start` / `end` slice the JSON output (full transcript is always
/// indexed). `metadataOnly` strips blocks but preserves token estimates and chapters.
enum SenseTool {

    static func call(arguments: [String: Any]) async throws -> String {
        guard let url = arguments["url"] as? String, !url.isEmpty else {
            throw McpToolError.missingArgument("url")
        }

        let outputFormat = arguments["outputFormat"] as? String ?? "json"
        let browserArg   = arguments["cookiesFromBrowser"] as? String
        let noSponsors   = arguments["noSponsors"]   as? Bool ?? false
        let metadataOnly = arguments["metadataOnly"] as? Bool ?? false
        let startStr     = arguments["start"] as? String
        let endStr       = arguments["end"]   as? String

        let browser: String? = (browserArg == nil || browserArg == "none") ? nil : browserArg

        // Pre-flight: parse and validate start / end before touching the network.
        let parsedStart: Double
        let parsedEnd: Double

        if let s = startStr {
            guard let v = TimeParser.parseToSeconds(s) else {
                let err = VvxError(code: .parseError,
                                   message: "Cannot parse start value '\(s)'.",
                                   url: url)
                return VvxErrorEnvelope(error: err).jsonString()
            }
            parsedStart = v
        } else {
            parsedStart = 0.0
        }

        if let e = endStr {
            guard let v = TimeParser.parseToSeconds(e) else {
                let err = VvxError(code: .parseError,
                                   message: "Cannot parse end value '\(e)'.",
                                   url: url)
                return VvxErrorEnvelope(error: err).jsonString()
            }
            parsedEnd = v
        } else {
            parsedEnd = Double.infinity
        }

        if parsedStart >= parsedEnd {
            let err = VvxError(
                code: .invalidTimeRange,
                message: "Invalid time range: start (\(parsedStart)s) must be strictly less than end (\(parsedEnd)s).",
                url: url)
            return VvxErrorEnvelope(error: err).jsonString()
        }

        let isSliced = startStr != nil || endStr != nil

        let resolver = EngineResolver.cliResolver
        guard let ytDlpURL = resolver.resolvedYtDlpURL() else {
            let err = VvxError(code: .engineNotFound,
                               message: "yt-dlp not found.",
                               url: url)
            return VvxErrorEnvelope(error: err).jsonString()
        }

        let config   = VvxConfig.load()
        let outDir   = config.resolvedTranscriptDirectory()

        let senseConfig = SenseConfig(
            url: url,
            outputDirectory: outDir,
            ytDlpPath: ytDlpURL,
            browserCookies: browser,
            removeSponsorSegments: noSponsors
        )

        let senser = VideoSenser()
        var senseResult: SenseResult?
        var senseError: VvxError?

        for await event in senser.sense(config: senseConfig) {
            switch event {
            case .completed(let result):    senseResult = result
            case .failed(let error):        senseError = error
            case .preparing:                log("sense: preparing \(url)")
            case .milestone(let milestone): log("sense: \(milestone.label)")
            case .retrying:                 log("sense: retrying after engine update")
            @unknown default:               break
            }
        }

        if let error = senseError {
            return VvxErrorEnvelope(error: error).jsonString()
        }

        guard let result = senseResult else {
            let err = VvxError(code: .unknownError,
                               message: "Sense completed without a result.",
                               url: url)
            return VvxErrorEnvelope(error: err).jsonString()
        }

        return format(result: result,
                      outputFormat: outputFormat,
                      metadataOnly: metadataOnly,
                      isSliced: isSliced,
                      parsedStart: parsedStart,
                      parsedEnd: parsedEnd)
    }

    // MARK: - Output formatting

    private static func format(
        result: SenseResult,
        outputFormat: String,
        metadataOnly: Bool,
        isSliced: Bool,
        parsedStart: Double,
        parsedEnd: Double
    ) -> String {
        // Apply slicing to output (DB always received full result upstream).
        let outputResult: SenseResult
        if isSliced {
            outputResult = result.sliced(startSeconds: parsedStart, endSeconds: parsedEnd)
        } else {
            outputResult = result
        }

        switch outputFormat {
        case "transcript":
            if !outputResult.transcriptBlocks.isEmpty {
                return outputResult.transcriptBlocks.map(\.text).joined(separator: " ")
            }
            return outputResult.transcriptText()
                .map { SenseResult.stripSRTTimestamps($0) }
                ?? "No transcript available."

        case "markdown":
            return outputResult.markdownDocument()

        default: // "json"
            let finalResult = metadataOnly ? outputResult.withEmptyBlocks() : outputResult
            return finalResult.jsonString()
        }
    }
}
