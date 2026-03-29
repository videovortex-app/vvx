import ArgumentParser
import Foundation
import VideoVortexCore

struct SqlCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sql",
        abstract: "Run read-only SQL analytics against vortex.db.",
        discussion: """
        Execute a single SELECT query against ~/.vvx/vortex.db for metadata analytics.
        Only SELECT statements are permitted — mutations are rejected at the OS level
        (SQLITE_OPEN_READONLY connection) before any application-level check runs.

        Use --schema first to see table definitions before writing queries.
        Use --markdown to output results as a Markdown table (useful in --rag pipelines).

        Output is structured JSON on stdout. Errors are also structured JSON so agent
        pipelines can branch deterministically.

        Examples:
          vvx sql --schema
          vvx sql "SELECT uploader, COUNT(*) AS videos FROM videos GROUP BY uploader ORDER BY videos DESC LIMIT 5"
          vvx sql "SELECT platform, AVG(duration_seconds) AS avg_duration FROM videos GROUP BY platform"
          vvx sql "SELECT COUNT(*) AS total, SUM(duration_seconds)/3600 AS hours FROM videos"
          vvx sql "SELECT title, sensed_at FROM videos WHERE video_path IS NOT NULL ORDER BY sensed_at DESC LIMIT 10" --markdown
        """
    )

    @Argument(help: "A single SELECT statement to execute against vortex.db.")
    var query: String?

    @Flag(name: .long, help: "Print CREATE TABLE definitions for all tables, then exit.")
    var schema: Bool = false

    @Flag(name: .long, help: "Output query results as a Markdown table instead of JSON.")
    var markdown: Bool = false

    mutating func run() async throws {
        let db: VortexDB
        do {
            db = try VortexDB.open()
        } catch {
            printError(
                message:     "Could not open vortex.db: \(error.localizedDescription)",
                agentAction: "Run 'vvx doctor' to check database health."
            )
            throw ExitCode(1)
        }

        // ── --schema mode ──────────────────────────────────────────────────────────
        if schema {
            let schemas: [String]
            do {
                schemas = try await db.tableSchema()
            } catch {
                printError(
                    message:     "Could not read schema: \(error.localizedDescription)",
                    agentAction: "Run 'vvx doctor' to check database health."
                )
                throw ExitCode(1)
            }

            if markdown {
                for s in schemas {
                    print("```sql\n\(s)\n```\n")
                }
            } else {
                let result: [String: Any] = ["success": true, "schemas": schemas]
                printJSON(result)
            }
            return
        }

        // ── Query mode ─────────────────────────────────────────────────────────────
        guard let query else {
            printError(
                message:     "Provide a SQL query or use --schema.",
                agentAction: "Run 'vvx sql --schema' to see available tables, then retry with a SELECT query."
            )
            throw ExitCode(1)
        }

        let result: SQLQueryResult
        do {
            result = try await db.executeReadOnlyIsolated(query)
        } catch VortexDBError.notReadOnly {
            printError(
                message:     "Only a single SELECT statement is permitted. Mutating statements and multi-statement input are rejected.",
                agentAction: "Rewrite your query as a single SELECT. Run 'vvx sql --schema' to see available tables."
            )
            throw ExitCode(1)
        } catch {
            printError(
                message:     "Query failed: \(error.localizedDescription)",
                agentAction: "Run 'vvx sql --schema' to verify table and column names, then retry."
            )
            throw ExitCode(1)
        }

        if markdown {
            printMarkdownTable(result)
        } else {
            printJSONResult(result, query: query)
        }
    }

    // MARK: - JSON output

    private func printJSONResult(_ result: SQLQueryResult, query: String) {
        // Convert to [[String: Any]] preserving column order for JSON arrays-of-objects.
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
        printJSON(envelope)
    }

    // MARK: - Markdown output

    private func printMarkdownTable(_ result: SQLQueryResult) {
        guard !result.columns.isEmpty else {
            print("*(no columns)*")
            return
        }
        if result.rows.isEmpty {
            print("*(no rows returned)*")
            return
        }
        print("| " + result.columns.joined(separator: " | ") + " |")
        print("| " + result.columns.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in result.rows {
            let cells = zip(result.columns, row).map { _, val in val ?? "NULL" }
            print("| " + cells.joined(separator: " | ") + " |")
        }
    }

    // MARK: - Error output

    private func printError(message: String, agentAction: String) {
        let envelope: [String: Any] = [
            "success": false,
            "error": [
                "code":        VvxErrorCode.sqlInvalid.rawValue,
                "message":     message,
                "agentAction": agentAction
            ] as [String: Any]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]),
           let str  = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    // MARK: - JSON helpers

    private func printJSON(_ dict: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let str  = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
