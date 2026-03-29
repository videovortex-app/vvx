import Foundation
import VideoVortexCore

/// MCP implementation of the `reindex` tool.
///
/// Rebuilds transcript_blocks in vortex.db, backfilling chapter_index for all videos.
/// Fully idempotent (delete-before-insert). Run after upgrading to schema v3 or after
/// manually editing transcript data.
///
/// MCP transport rules: all per-video NDJSON output is aggregated in memory and returned
/// as one text block. CLI stderr progress is suppressed.
enum ReindexTool {

    static func call(arguments: [String: Any]) async throws -> String {
        let dryRun = arguments["dryRun"] as? Bool ?? false

        let db: VortexDB
        do {
            db = try VortexDB.open()
        } catch {
            let err = VvxError(code: .indexEmpty,
                               message: "Could not open vortex.db: \(error.localizedDescription)")
            return VvxErrorEnvelope(error: err).jsonString()
        }

        let videos: [VideoRecord]
        do {
            videos = try await db.allVideos()
        } catch {
            let err = VvxError(code: .indexEmpty,
                               message: "Could not read videos: \(error.localizedDescription)")
            return VvxErrorEnvelope(error: err).jsonString()
        }

        let total = videos.count

        if total == 0 {
            let obj: [String: Any] = ["success": true, "reindexed": 0, "skipped": 0, "dryRun": dryRun]
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                  let str  = String(data: data, encoding: .utf8) else { return "{}" }
            return str
        }

        var lines: [String] = []
        var reindexed = 0
        var skipped   = 0

        for record in videos {
            guard record.transcriptPath != nil else {
                skipped += 1
                lines.append(ndjsonLine(["success": false, "id": record.id, "title": record.title, "reason": "no_srt"]))
                continue
            }

            if dryRun {
                reindexed += 1
                lines.append(ndjsonLine(["success": true, "id": record.id, "title": record.title, "dryRun": true]))
                continue
            }

            do {
                let updated = try await VortexIndexer.reindexOne(record: record, db: db)
                if updated {
                    reindexed += 1
                    lines.append(ndjsonLine([
                        "success":     true,
                        "id":          record.id,
                        "title":       record.title,
                        "reindexedAt": iso8601Now()
                    ]))
                } else {
                    skipped += 1
                    lines.append(ndjsonLine(["success": false, "id": record.id, "title": record.title, "reason": "no_srt"]))
                }
            } catch {
                skipped += 1
                lines.append(ndjsonLine([
                    "success": false,
                    "id":      record.id,
                    "title":   record.title,
                    "reason":  error.localizedDescription
                ]))
            }
        }

        // Summary line last.
        lines.append(ndjsonLine([
            "success":   true,
            "summary":   true,
            "reindexed": reindexed,
            "skipped":   skipped,
            "total":     total,
            "dryRun":    dryRun
        ]))

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func ndjsonLine(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str  = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func iso8601Now() -> String {
        isoFormatter.string(from: Date())
    }
}
