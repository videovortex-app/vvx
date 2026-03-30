import Foundation
import VideoVortexCore

/// MCP implementation of the `search` tool.
///
/// Three modes:
///   - Standard FTS (default): provide `query` + `outputFormat`.
///   - Structural: set `longestMonologue` or `highDensity` (no query needed).
///   - Proximity: provide `query` with explicit AND + set `within` (seconds).
///
/// `outputFormat` is required for standard FTS only; ignored for structural/proximity.
enum SearchTool {

    static func call(arguments: [String: Any]) async throws -> String {
        let longestMonologue = arguments["longestMonologue"] as? Bool ?? false
        let highDensity      = arguments["highDensity"]      as? Bool ?? false
        let within           = arguments["within"]           as? Double
        let isStructural     = longestMonologue || highDensity
        let isProximity      = within != nil

        // ── Mutual-exclusion validation ─────────────────────────────────────
        let query       = arguments["query"] as? String
        let hasQuery    = !(query ?? "").isEmpty
        let monologueGap  = arguments["monologueGap"]  as? Double ?? 1.5
        let densityWindow = arguments["densityWindow"] as? Double ?? 60.0

        if !hasQuery && !isStructural && !isProximity {
            return VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "A search query is required unless longestMonologue or highDensity is set."
            )).jsonString()
        }
        if isStructural && hasQuery {
            return VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "longestMonologue/highDensity cannot be combined with a query."
            )).jsonString()
        }
        if longestMonologue && highDensity {
            return VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "longestMonologue and highDensity cannot be used together."
            )).jsonString()
        }
        if isStructural && isProximity {
            return VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "within cannot be combined with structural flags."
            )).jsonString()
        }
        if isProximity && !hasQuery {
            return VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "within requires a search query with explicit AND."
            )).jsonString()
        }
        if let w = within, w <= 0 {
            return VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "within must be > 0."
            )).jsonString()
        }
        if monologueGap < 0 {
            return VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "monologueGap must be ≥ 0."
            )).jsonString()
        }
        if densityWindow <= 0 {
            return VvxErrorEnvelope(error: VvxError(
                code: .parseError,
                message: "densityWindow must be > 0."
            )).jsonString()
        }

        let limit    = arguments["limit"]    as? Int    ?? 50
        let platform = arguments["platform"] as? String
        let after    = arguments["after"]    as? String
        let uploader = arguments["uploader"] as? String

        // ── Structural dispatch ──────────────────────────────────────────────
        if isStructural {
            let config = SearchStructuralConfig(
                longestMonologue: longestMonologue,
                highDensity:      highDensity,
                monologueGap:     monologueGap,
                densityWindow:    densityWindow,
                limit:            limit,
                platform:         platform,
                uploader:         uploader,
                after:            after
            )
            return await SearchEngine.runStructural(config: config)
        }

        // ── Proximity dispatch ───────────────────────────────────────────────
        if isProximity {
            guard let q = query, !q.isEmpty else {
                return VvxErrorEnvelope(error: VvxError(
                    code: .parseError,
                    message: "within requires a search query with explicit AND."
                )).jsonString()
            }
            let config = SearchProximityConfig(
                query:         q,
                withinSeconds: within!,
                limit:         limit,
                platform:      platform,
                uploader:      uploader,
                after:         after
            )
            return await SearchEngine.runProximity(config: config)
        }

        // ── Standard FTS (unchanged) ─────────────────────────────────────────
        guard let q = query, !q.isEmpty else {
            throw McpToolError.missingArgument("query")
        }
        guard let outputFormat = arguments["outputFormat"] as? String else {
            throw McpToolError.missingArgument("outputFormat")
        }

        let maxTokens = arguments["maxTokens"] as? Int

        let db: VortexDB
        do {
            db = try VortexDB.open()
        } catch {
            let err = VvxError(code: .indexEmpty,
                               message: "Could not open vortex.db: \(error.localizedDescription)")
            return VvxErrorEnvelope(error: err).jsonString()
        }

        let output: SearchOutput
        do {
            output = try await SRTSearcher.search(
                query:     q,
                db:        db,
                platform:  platform,
                afterDate: after,
                uploader:  uploader,
                limit:     limit
            )
        } catch {
            let err = VvxError(code: .indexEmpty,
                               message: "Search failed: \(error.localizedDescription)")
            return VvxErrorEnvelope(error: err).jsonString()
        }

        switch outputFormat.lowercased() {
        case "rag":
            return SRTSearcher.ragMarkdown(
                query:             q,
                results:           output.results,
                totalBeforeBudget: output.totalMatches,
                maxTokens:         maxTokens
            )
        default: // "json"
            return output.jsonString()
        }
    }
}
