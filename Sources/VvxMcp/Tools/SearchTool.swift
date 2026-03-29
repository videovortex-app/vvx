import Foundation
import VideoVortexCore

/// MCP implementation of the `search` tool.
///
/// Full CLI parity with SearchCommand: FTS5 query, optional platform/after/uploader
/// filters, and two output formats.
///
/// `outputFormat` is REQUIRED (no default). The LLM must explicitly choose:
///   - "json"  → structured SearchOutput payload; use when chaining to ClipTool
///   - "rag"   → Markdown context document with clip commands; use for human-readable answers
///
/// Agents: prefer "rag" for answering user questions, "json" for pipelines.
enum SearchTool {

    static func call(arguments: [String: Any]) async throws -> String {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            throw McpToolError.missingArgument("query")
        }
        guard let outputFormat = arguments["outputFormat"] as? String else {
            throw McpToolError.missingArgument("outputFormat")
        }

        let limit     = arguments["limit"]    as? Int    ?? 50
        let platform  = arguments["platform"] as? String
        let after     = arguments["after"]    as? String
        let uploader  = arguments["uploader"] as? String
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
                query:     query,
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
                query:             query,
                results:           output.results,
                totalBeforeBudget: output.totalMatches,
                maxTokens:         maxTokens
            )
        default: // "json"
            return output.jsonString()
        }
    }
}
