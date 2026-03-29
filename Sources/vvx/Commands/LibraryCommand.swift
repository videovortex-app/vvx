import ArgumentParser
import Foundation
import VideoVortexCore

struct LibraryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "library",
        abstract: "List all videos in your local archive.",
        discussion: """
        Queries vortex.db and lists archived/sensed videos. Default output is a
        human-readable table on stderr. Use --json for machine-readable NDJSON on stdout.

        stdout/stderr contract (UNIX):
          • Human table  → stderr  (safe to pipe; stdout stays clean)
          • --json NDJSON → stdout
          • --paths-only  → stdout (one path per line)

        Use --downloaded to filter to videos with a local MP4 on disk — the Phase 3.5
        bridge for editing workflows. Combine with --paths-only to pipe directly into
        vvx clip or ffmpeg.

        Sort is deterministic: newest sensed_at first by default.

        Examples:
          vvx library
          vvx library --platform YouTube --limit 20
          vvx library --uploader "Lex Fridman"
          vvx library --downloaded
          vvx library --downloaded --paths-only
          vvx library --downloaded --paths-only | xargs -I{} vvx clip "{}" --start 0:00 --end 0:30
          vvx library --json
        """
    )

    @Option(name: .long, help: "Maximum number of results to return.")
    var limit: Int?

    @Option(name: .long, help: "Filter by platform (e.g. YouTube, TikTok, Twitter).")
    var platform: String?

    @Option(name: .long, help: "Filter by uploader or channel name (exact match).")
    var uploader: String?

    @Option(name: .long, help: "Sort order: newest (default), oldest, title, duration.")
    var sort: String = "newest"

    @Flag(name: .long, help: "Only show videos that have a downloaded MP4 file on disk.")
    var downloaded: Bool = false

    @Flag(name: .long, help: "Output only video file paths to stdout, one per line. Implies --downloaded.")
    var pathsOnly: Bool = false

    @Flag(name: .long, help: "Output NDJSON to stdout instead of a human-readable table.")
    var json: Bool = false

    mutating func run() async throws {
        let db: VortexDB
        do {
            db = try VortexDB.open()
        } catch {
            fputs("vvx library: could not open database — \(error.localizedDescription)\n", stderr)
            throw ExitCode(1)
        }

        // --paths-only implies --downloaded (you can only pipe paths that exist)
        let effectiveDownloaded = downloaded || pathsOnly

        let records: [VideoRecord]
        do {
            records = try await db.library(
                platform:   platform,
                uploader:   uploader,
                downloaded: effectiveDownloaded,
                limit:      limit,
                sort:       sort
            )
        } catch {
            fputs("vvx library: query failed — \(error.localizedDescription)\n", stderr)
            throw ExitCode(1)
        }

        if records.isEmpty {
            let hint = effectiveDownloaded
                ? "No downloaded videos found. Run `vvx sync <url> --archive` to download media files."
                : "No videos found. Run `vvx sync <url>` to populate your archive."
            fputs("\(hint)\n", stderr)
            return
        }

        // --- Output modes ---

        if pathsOnly {
            // Pure stdout: one path per line — safe for xargs, while-read, etc.
            for record in records {
                if let path = record.videoPath {
                    print(path)
                }
            }
            return
        }

        if json {
            for record in records {
                if let line = ndjsonLine(record) { print(line) }
            }
            return
        }

        // Human-readable table → stderr so pipes stay clean.
        printTable(records)
    }

    // MARK: - Human table (stderr)

    private func printTable(_ records: [VideoRecord]) {
        let rows: [[String]] = records.map { r in [
            String(r.title.prefix(44)),
            r.platform ?? "—",
            r.durationSeconds.map { formatDuration($0) } ?? "—",
            String(r.sensedAt.prefix(10)),
            r.videoPath != nil ? "✓" : "—"
        ]}

        let headers = ["Title", "Platform", "Duration", "Sensed", "Video"]
        var widths  = headers.map(\.count)
        for row in rows {
            for (i, cell) in row.enumerated() {
                widths[i] = max(widths[i], cell.count)
            }
        }

        let divLine  = widths.map { String(repeating: "─", count: $0 + 2) }
        let topBorder    = "┌" + divLine.joined(separator: "┬") + "┐"
        let midBorder    = "├" + divLine.joined(separator: "┼") + "┤"
        let bottomBorder = "└" + divLine.joined(separator: "┴") + "┘"
        let headerLine   = "│" + zip(headers, widths)
            .map { h, w in " \(h.padding(toLength: w, withPad: " ", startingAt: 0)) " }
            .joined(separator: "│") + "│"

        fputs(topBorder    + "\n", stderr)
        fputs(headerLine   + "\n", stderr)
        fputs(midBorder    + "\n", stderr)
        for row in rows {
            let line = "│" + zip(row, widths)
                .map { cell, w in " \(cell.padding(toLength: w, withPad: " ", startingAt: 0)) " }
                .joined(separator: "│") + "│"
            fputs(line + "\n", stderr)
        }
        fputs(bottomBorder + "\n", stderr)
        fputs("\(records.count) video(s)\n", stderr)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    // MARK: - NDJSON (stdout)

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

    private func ndjsonLine(_ record: VideoRecord) -> String? {
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

// MARK: - Helpers

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
