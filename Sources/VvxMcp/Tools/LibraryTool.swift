import Foundation
import VideoVortexCore

/// MCP implementation of the `library` tool.
///
/// Lists all indexed/archived videos from vortex.db.
/// Mirrors LibraryCommand with optional filters.
/// Returns aggregated NDJSON (one VideoRecord per line) in a single text block.
enum LibraryTool {

    static func call(arguments: [String: Any]) async throws -> String {
        let limit      = arguments["limit"]      as? Int
        let platform   = arguments["platform"]   as? String
        let uploader   = arguments["uploader"]   as? String
        let downloaded = arguments["downloaded"] as? Bool ?? false
        let sort       = arguments["sort"]       as? String ?? "newest"

        let db: VortexDB
        do {
            db = try VortexDB.open()
        } catch {
            let err = VvxError(code: .indexEmpty,
                               message: "Could not open vortex.db: \(error.localizedDescription)")
            return VvxErrorEnvelope(error: err).jsonString()
        }

        let records: [VideoRecord]
        do {
            records = try await db.library(
                platform:   platform,
                uploader:   uploader,
                downloaded: downloaded,
                limit:      limit,
                sort:       sort
            )
        } catch {
            let err = VvxError(code: .indexEmpty,
                               message: "Library query failed: \(error.localizedDescription)")
            return VvxErrorEnvelope(error: err).jsonString()
        }

        if records.isEmpty {
            let hint = downloaded
                ? "No downloaded videos found. Run `vvx sync <url> --archive` to download media files."
                : "No videos found. Run `vvx sync <url>` to populate your archive."
            let obj: [String: Any] = [
                "success": true,
                "totalRecords": 0,
                "records": [Any](),
                "hint": hint
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                  let str  = String(data: data, encoding: .utf8) else { return "{}" }
            return str
        }

        // Aggregate NDJSON lines.
        let lines = records.compactMap { ndjsonLine($0) }
        return lines.joined(separator: "\n")
    }

    // MARK: - NDJSON line

    private struct LibraryRecord: Encodable {
        let id: String
        let title: String
        let platform: String?
        let uploader: String?
        let durationSeconds: Int?
        let uploadDate: String?
        let sensedAt: String
        let archivedAt: String?
        let videoPath: String?
        let transcriptPath: String?
        let viewCount: Int?
        let likeCount: Int?
        let commentCount: Int?
    }

    private static func ndjsonLine(_ record: VideoRecord) -> String? {
        let lib = LibraryRecord(
            id:              record.id,
            title:           record.title,
            platform:        record.platform,
            uploader:        record.uploader,
            durationSeconds: record.durationSeconds,
            uploadDate:      record.uploadDate,
            sensedAt:        record.sensedAt,
            archivedAt:      record.archivedAt,
            videoPath:       record.videoPath,
            transcriptPath:  record.transcriptPath,
            viewCount:       record.viewCount,
            likeCount:       record.likeCount,
            commentCount:    record.commentCount
        )
        guard let data = try? JSONEncoder().encode(lib),
              let str  = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}
