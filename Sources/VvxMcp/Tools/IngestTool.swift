import Foundation
import VideoVortexCore

/// MCP implementation of the `ingest` tool.
///
/// Thin wrapper: parses arguments, resolves `path` to an absolute URL, then
/// delegates entirely to `IngestEngine.run()`. No print() calls — the engine
/// returns a newline-joined NDJSON string whose last line is always
/// `IngestSummaryLine` (`"type":"summary"`).
///
/// MCP passes `nil` for the progress callback so the tool return stays a single
/// NDJSON blob with no interleaved stderr heartbeats.
enum IngestTool {

    static func call(arguments: [String: Any]) async throws -> String {
        // 1 — Required argument
        guard let rawPath = arguments["path"] as? String, !rawPath.isEmpty else {
            return VvxErrorEnvelope(error: VvxError(
                code:    .permissionDenied,
                message: "ingest: missing required argument 'path'.",
                agentAction: "Supply a valid, readable directory path and retry."
            )).jsonString()
        }

        // 2 — Optional arguments
        let dryRun       = arguments["dryRun"]       as? Bool ?? false
        let forceReindex = arguments["forceReindex"] as? Bool ?? false

        // 3 — Resolve to absolute URL (mirrors IngestCommand path resolution)
        let resolvedURL = URL(fileURLWithPath: rawPath).standardizedFileURL

        // 4 — Validate: must be a readable directory (fast-fail before engine)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: resolvedURL.path, isDirectory: &isDir
        )
        guard exists, isDir.boolValue else {
            let msg = exists
                ? "ingest: path is not a directory: \(resolvedURL.path)"
                : "ingest: directory not found: \(resolvedURL.path)"
            return VvxErrorEnvelope(error: VvxError(
                code:    .permissionDenied,
                message: msg,
                agentAction: "Supply a valid, readable directory path and retry."
            )).jsonString()
        }

        // 5 — Build config and delegate to engine; MCP omits progress callback
        let config = IngestConfig(
            rootURL:      resolvedURL,
            dryRun:       dryRun,
            forceReindex: forceReindex
        )
        return await IngestEngine.run(config: config, progress: nil)
    }
}
