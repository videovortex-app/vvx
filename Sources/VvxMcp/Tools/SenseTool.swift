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
        let moments      = arguments["moments"]      as? Bool ?? false
        let momentLimit  = arguments["momentLimit"]  as? Int  ?? 4
        let momentQuery  = arguments["momentQuery"]  as? String
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
        if momentLimit <= 0 {
            let err = VvxError(
                code: .parseError,
                message: "momentLimit must be > 0.",
                url: url)
            return VvxErrorEnvelope(error: err).jsonString()
        }
        if let momentQuery,
           !momentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !moments {
            let err = VvxError(
                code: .parseError,
                message: "momentQuery requires moments=true.",
                url: url)
            return VvxErrorEnvelope(error: err).jsonString()
        }

        let isSliced = startStr != nil || endStr != nil

        if let cached = await cachedSenseResult(url: url) {
            log("sense: vortex.db cache hit \(url)")
            return format(result: cached,
                          outputFormat: outputFormat,
                          metadataOnly: metadataOnly,
                          moments: moments,
                          momentLimit: momentLimit,
                          momentQuery: momentQuery,
                          isSliced: isSliced,
                          parsedStart: parsedStart,
                          parsedEnd: parsedEnd)
        }

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
                      moments: moments,
                      momentLimit: momentLimit,
                      momentQuery: momentQuery,
                      isSliced: isSliced,
                      parsedStart: parsedStart,
                      parsedEnd: parsedEnd)
    }

    private static func cachedSenseResult(url: String) async -> SenseResult? {
        do {
            let db = try VortexDB.open()
            return try await db.senseResultFromCache(videoId: url)
        } catch {
            return nil
        }
    }

    // MARK: - Output formatting

    private static func format(
        result: SenseResult,
        outputFormat: String,
        metadataOnly: Bool,
        moments: Bool,
        momentLimit: Int,
        momentQuery: String?,
        isSliced: Bool,
        parsedStart: Double,
        parsedEnd: Double
    ) -> String {
        // Apply slicing to output (DB always received full result upstream).
        var outputResult: SenseResult
        if isSliced {
            outputResult = result.sliced(startSeconds: parsedStart, endSeconds: parsedEnd)
        } else {
            outputResult = result
        }

        if moments && outputFormat.lowercased() == "json" {
            let ranked: [RankedMoment]
            if let momentQuery, !momentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ranked = MomentRanker.rankQuery(
                    result: outputResult,
                    query: momentQuery,
                    config: MomentRankerConfig(limit: momentLimit)
                ).rankedMoments
            } else {
                ranked = MomentRanker.rankedMoments(for: outputResult, limit: momentLimit)
            }
            outputResult = outputResult.withRankedMoments(ranked)
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
