import ArgumentParser
import Foundation
import VideoVortexCore

struct ReindexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reindex",
        abstract: "Rebuild vortex.db from on-disk truth — the disaster-recovery engine for vvx.",
        discussion: """
        DISASTER RECOVERY
          rm ~/.vvx/vortex.db && vvx reindex
        This is the official, one-command path to rebuild a corrupt, deleted, or
        schema-migrated database from local files.

        HOW IT WORKS
        Phase 1 — Discovery: scans ~/.vvx/archive/ for yt-dlp .info.json sidecars
          (written during `vvx fetch --archive`).  Each sidecar carries the canonical
          URL, title, metadata, chapters, and engagement counts (like/comment).  The
          companion .srt in the same folder is parsed and indexed with chapter_index.

        Phase 2 — Backfill: iterates every video already in vortex.db (including rows
          just discovered), re-parses its stored SRT, and recomputes chapter_index using
          the same boundary logic as `vvx sense`.  Fully idempotent — safe to run
          multiple times with identical results.

        LIMITATIONS
          Sense-only transcripts in ~/.vvx/transcripts/ cannot be recovered from disk
          alone: `vvx sense` uses --no-write-info-json, so no sidecar carries the URL.
          Those rows are only re-parseable when vortex.db already contains them.

        stdout/stderr contract (UNIX):
          • Progress per video    → stderr  ([n/total] ...)
          • Final summary         → stderr
          • One NDJSON line/video → stdout  (agents can stream this)

        Use --dry-run to preview without writes.  Use --force to re-import videos that
        are already indexed (refreshes engagement counts and chapter_index from disk).

        Examples:
          vvx reindex
          vvx reindex --dry-run
          vvx reindex --force
        """
    )

    @Flag(name: .long, help: "Preview what would be discovered / reindexed without writing.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Re-import archive videos already in vortex.db (refreshes metadata from .info.json).")
    var force: Bool = false

    mutating func run() async throws {
        let db: VortexDB
        do {
            db = try VortexDB.open()
        } catch {
            fputs("vvx reindex: could not open database — \(error.localizedDescription)\n", stderr)
            throw ExitCode(1)
        }

        // Phase 0 — Legacy index.json
        // If ~/.vvx/index.json exists (pre-Phase-3 flat index), archive it so it is never
        // re-imported on subsequent runs.  Records cannot be reliably recovered from that
        // format because the schema is undefined; discovery from .info.json sidecars
        // (Phase 1) is the correct rebuild path.
        let legacyIndexURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vvx/index.json")
        if FileManager.default.fileExists(atPath: legacyIndexURL.path) {
            let bakURL = legacyIndexURL.deletingPathExtension().appendingPathExtension("json.bak")
            fputs("Found legacy ~/.vvx/index.json — archiving to index.json.bak (one-time migration).\n", stderr)
            if !dryRun {
                try? FileManager.default.moveItem(at: legacyIndexURL, to: bakURL)
            }
        }

        // Phase 1 — Archive discovery
        // Walk ~/.vvx/archive/ for .info.json sidecars and import any video not yet in
        // vortex.db.  This is the key DR step: rebuilds the index from on-disk truth
        // when the database has been deleted or is empty.
        let config     = VvxConfig.load()
        let archiveDir = config.resolvedArchiveDirectory()

        if FileManager.default.fileExists(atPath: archiveDir.path) {
            fputs(dryRun
                ? "Dry run — scanning \(archiveDir.path) for unindexed archives...\n"
                : "Scanning \(archiveDir.path) for unindexed archives...\n",
                  stderr)

            if dryRun {
                // In dry-run mode count .info.json sidecars without writing.
                // collectInfoJSONURLs is synchronous to avoid the Swift 6 async-context warning.
                let infoJSONCount = collectInfoJSONURLs(in: archiveDir).count
                let existing      = (try? await db.allVideos())?.count ?? 0
                let wouldSkip     = force ? 0 : min(existing, infoJSONCount)
                let wouldDiscover = force ? infoJSONCount : max(0, infoJSONCount - wouldSkip)
                fputs("Dry run — would discover \(wouldDiscover) archive(s), skip \(wouldSkip) already indexed.\n", stderr)
                printNDJSON(["success": true, "wouldDiscover": wouldDiscover, "wouldSkip": wouldSkip, "dryRun": true])
            } else {
                do {
                    let (disc, skip) = try await VortexIndexer.discoverArchived(
                        in:    archiveDir,
                        db:    db,
                        force: force,
                        progressCallback: { url, imported in
                            let label  = URL(string: url)?.lastPathComponent ?? url
                            let prefix = imported ? "Discovered" : "Skipped (already indexed)"
                            fputs("  \(prefix): \(label)\n", stderr)
                        }
                    )
                    if disc > 0 || skip > 0 {
                        fputs("Discovery: imported \(disc), skipped \(skip) already indexed.\n", stderr)
                    }
                } catch {
                    fputs("vvx reindex: archive discovery error — \(error.localizedDescription)\n", stderr)
                    // Non-fatal: continue with backfill phase.
                }
            }
        }

        // Phase 2 — Backfill
        // Re-parse SRTs for every video in vortex.db (including newly discovered rows)
        // and recompute chapter_index using the same boundary logic as `vvx sense`.
        let videos: [VideoRecord]
        do {
            videos = try await db.allVideos()
        } catch {
            fputs("vvx reindex: could not read videos — \(error.localizedDescription)\n", stderr)
            throw ExitCode(1)
        }

        let total = videos.count

        if total == 0 {
            fputs("vortex.db is empty after discovery — nothing to backfill.\n", stderr)
            fputs("Note: sense-only transcripts cannot be recovered from disk without the DB.\n", stderr)
            printNDJSON(["success": true, "discovered": 0, "reindexed": 0, "skipped": 0, "dryRun": dryRun])
            return
        }

        fputs(dryRun
            ? "Dry run — would backfill \(total) video(s) (no writes)...\n"
            : "Backfilling chapter_index for \(total) video(s)...\n",
              stderr)

        var reindexed = 0
        var skipped   = 0

        for (i, record) in videos.enumerated() {
            let label    = record.title.isEmpty ? record.id : record.title
            let position = "[\(i + 1)/\(total)]"

            guard record.transcriptPath != nil else {
                fputs("\(position) Skipped (no SRT): \(label)\n", stderr)
                printNDJSON([
                    "success": false,
                    "id":      record.id,
                    "title":   record.title,
                    "reason":  "no_srt"
                ])
                skipped += 1
                continue
            }

            fputs("\(position) \(dryRun ? "Would backfill" : "Backfilling"): \(label)\n", stderr)

            if dryRun {
                reindexed += 1
                printNDJSON([
                    "success": true,
                    "id":      record.id,
                    "title":   record.title,
                    "dryRun":  true
                ])
                continue
            }

            do {
                let updated = try await VortexIndexer.reindexOne(record: record, db: db)
                if updated {
                    reindexed += 1
                    printNDJSON([
                        "success":      true,
                        "id":           record.id,
                        "title":        record.title,
                        "reindexedAt":  iso8601Now()
                    ])
                } else {
                    skipped += 1
                    printNDJSON([
                        "success": false,
                        "id":      record.id,
                        "title":   record.title,
                        "reason":  "no_srt"
                    ])
                }
            } catch {
                skipped += 1
                fputs("\(position) Error: \(error.localizedDescription)\n", stderr)
                printNDJSON([
                    "success": false,
                    "id":      record.id,
                    "title":   record.title,
                    "reason":  error.localizedDescription
                ])
            }
        }

        let verb = dryRun ? "Would backfill" : "Backfilled"
        fputs("Done. \(verb): \(reindexed)  Skipped (no SRT): \(skipped)\n", stderr)
    }

    // MARK: - Helpers

    private func printNDJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str  = String(data: data, encoding: .utf8) else { return }
        print(str)
    }

    nonisolated(unsafe) private static let _isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func iso8601Now() -> String {
        ReindexCommand._isoFormatter.string(from: Date())
    }
}

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}

/// Synchronous helper: collect all `.info.json` URLs under `directory` recursively.
/// Kept outside the struct so it runs without actor isolation and avoids the Swift 6
/// `DirectoryEnumerator.makeIterator` async-context warning.
private func collectInfoJSONURLs(in directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    var result: [URL] = []
    for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".info.json") {
        result.append(url)
    }
    return result
}
