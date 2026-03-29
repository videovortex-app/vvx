import Foundation
import VideoVortexCore

/// MCP implementation of the `sql` tool.
///
/// Runs a read-only SELECT query against ~/.vvx/vortex.db.
/// All non-SELECT statements are rejected at the OS level (SQLITE_OPEN_READONLY).
///
/// Schema cheat sheet (include this in tool descriptions so agents don't hallucinate):
///
///   videos (id TEXT PK, title TEXT, platform TEXT, uploader TEXT,
///           duration_seconds INTEGER, upload_date TEXT, sensed_at TEXT,
///           archived_at TEXT, transcript_path TEXT, video_path TEXT,
///           view_count INTEGER, tags TEXT, description TEXT)
///
///   transcript_blocks (video_id TEXT, block_index INTEGER, start_seconds REAL,
///                      end_seconds REAL, start_time TEXT, end_time TEXT,
///                      text TEXT, word_count INTEGER, estimated_tokens INTEGER,
///                      chapter_index INTEGER)
///
/// Returns aggregated JSON rows in one text block.
enum SqlTool {

    static func call(arguments: [String: Any]) async throws -> String {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            throw McpToolError.missingArgument("query")
        }

        let db: VortexDB
        do {
            db = try VortexDB.open()
        } catch {
            let err = VvxError(code: .sqlInvalid,
                               message: "Could not open vortex.db: \(error.localizedDescription)")
            return VvxErrorEnvelope(error: err).jsonString()
        }

        let result: SQLQueryResult
        do {
            result = try await db.executeReadOnlyIsolated(query)
        } catch VortexDBError.notReadOnly {
            let err = VvxError(
                code: .sqlInvalid,
                message: "Only a single SELECT statement is permitted. Mutating statements and multi-statement input are rejected.",
                agentAction: "Rewrite your query as a single SELECT. Run the 'sql' tool with query='SELECT name FROM sqlite_master WHERE type=\\'table\\'' to list available tables."
            )
            return VvxErrorEnvelope(error: err).jsonString()
        } catch {
            let err = VvxError(
                code: .sqlInvalid,
                message: "Query failed: \(error.localizedDescription)",
                agentAction: "Verify table and column names. Available tables: videos, transcript_blocks. Run with query='SELECT name FROM sqlite_master WHERE type=\\'table\\'' to confirm."
            )
            return VvxErrorEnvelope(error: err).jsonString()
        }

        // Build [[String: Any]] rows preserving column order.
        let jsonRows: [[String: Any]] = result.rows.map { row in
            var dict: [String: Any] = [:]
            for (col, val) in zip(result.columns, row) {
                dict[col] = val as Any? ?? NSNull()
            }
            return dict
        }

        let envelope: [String: Any] = [
            "success":  true,
            "query":    query,
            "rows":     jsonRows,
            "rowCount": result.rowCount
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]
        ), let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
