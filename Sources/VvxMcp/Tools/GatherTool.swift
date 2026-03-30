import Foundation
import VideoVortexCore

/// MCP implementation of the `gather` tool.
///
/// Thin wrapper: parses arguments, validates mutual-exclusion constraints,
/// gates on Pro entitlement, then delegates entirely to `GatherEngine.run()`.
/// No print() calls — the engine returns a newline-joined NDJSON string.
/// Last line is always `GatherSummaryLine` (summary:true); agents read
/// `outputDir` and `manifestPath` from it.
enum GatherTool {

    static func call(arguments: [String: Any]) async throws -> String {
        // 1 — Required arguments
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            throw McpToolError.missingArgument("query")
        }
        guard let limit = arguments["limit"] as? Int else {
            throw McpToolError.missingArgument("limit")
        }

        // 2 — Optional arguments
        let platform        = arguments["platform"]        as? String
        let after           = arguments["after"]           as? String
        let uploader        = arguments["uploader"]        as? String
        let minViews        = arguments["minViews"]        as? Int
        let minLikes        = arguments["minLikes"]        as? Int
        let minComments     = arguments["minComments"]     as? Int
        let contextSeconds  = arguments["contextSeconds"]  as? Double ?? 1.0
        let snapRaw         = arguments["snap"]            as? String
        let maxTotalDuration = arguments["maxTotalDuration"] as? Double
        let pad             = arguments["pad"]             as? Double ?? 2.0
        let dryRun          = arguments["dryRun"]          as? Bool   ?? false
        let fast            = arguments["fast"]            as? Bool   ?? false
        let exact           = arguments["exact"]           as? Bool   ?? false
        let thumbnails      = arguments["thumbnails"]      as? Bool   ?? false
        let embedSource     = arguments["embedSource"]     as? Bool   ?? false
        let chaptersOnly    = arguments["chaptersOnly"]    as? Bool   ?? false

        // 3 — Snap mode parsing
        let snapMode: SnapMode
        if let raw = snapRaw {
            guard let parsed = SnapMode(rawValue: raw) else {
                return VvxErrorEnvelope(error: VvxError(
                    code: .parseError,
                    message: "Invalid snap value '\(raw)'. Must be one of: off, block, chapter."
                )).jsonString()
            }
            snapMode = parsed
        } else {
            snapMode = .off
        }

        // 4 — Mutual-exclusion validation
        if fast && exact {
            return VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "--fast and --exact are mutually exclusive. Use fast for stream-copy speed or exact for frame-accurate re-encode, not both."
            )).jsonString()
        }

        if chaptersOnly, let raw = snapRaw, snapMode == .off || snapMode == .block {
            return VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "chaptersOnly=true is incompatible with snap='\(raw)'. chaptersOnly implies chapter boundaries; omit snap or set snap=chapter."
            )).jsonString()
        }

        // 5 — Entitlement gate
        do { try await EntitlementChecker.requirePro(.gather) }
        catch let err as VvxError { return VvxErrorEnvelope(error: err).jsonString() }

        // 6 — Build config and delegate to engine
        let config = GatherConfig(
            query:            query,
            limit:            limit,
            platform:         platform,
            after:            after,
            uploader:         uploader,
            minViews:         minViews,
            minLikes:         minLikes,
            minComments:      minComments,
            contextSeconds:   contextSeconds,
            snapMode:         snapMode,
            maxTotalDuration: maxTotalDuration,
            pad:              pad,
            dryRun:           dryRun,
            fast:             fast,
            exact:            exact,
            thumbnails:       thumbnails,
            embedSource:      embedSource,
            chaptersOnly:     chaptersOnly,
            outputDir:        nil   // auto-named; path returned in GatherSummaryLine.outputDir
        )
        return await GatherEngine.run(config: config)
    }
}
