import ArgumentParser
import Foundation
import VideoVortexCore

/// Phase 3.5 Step 9.5: thin wrapper over `IngestEngine`.
struct IngestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "Index local video files into vortex.db without moving or copying them.",
        discussion: """
        Recursively scans a local directory for video files (.mp4 by default),
        matches sibling sidecars (.srt, .info.json), and indexes discovered
        media into vortex.db using absolute paths — without moving, copying,
        or modifying any user files.

        Sidecars (same directory, same filename stem):
          .en.srt / .srt    Transcript; indexed as transcript_source "local".
          .info.json        yt-dlp-style metadata (title, uploader, etc.).

        Deduplication: files already in vortex.db are skipped unless
        --force-reindex is passed.

        stdout/stderr contract (UNIX):
          • NDJSON per file (indexed or skipped)   → stdout
          • Final summary line (type: "summary")   → stdout
          • Progress heartbeat every ~100 files    → stderr

        Examples:
          vvx ingest /Volumes/Projects/InterviewRushes
          vvx ingest ./rushes --dry-run
          vvx ingest /path/to/folder --force-reindex
          vvx ingest ~/Downloads --extensions mp4,mov,mkv
        """
    )

    // MARK: - Positional

    @Argument(help: "Folder path to scan (relative or absolute).")
    var path: String

    // MARK: - Flags

    @Flag(name: .long, help: "Walk the folder and match sidecars without writing to vortex.db or running ffprobe. Stderr heartbeats are prefixed with 'DRY-RUN: '.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Bypass dedup check and re-upsert metadata for paths already in vortex.db.")
    var forceReindex: Bool = false

    @Flag(name: .long, help: "Print additional skip detail to stderr.")
    var verbose: Bool = false

    // MARK: - Options

    @Option(name: .long, help: "Comma-separated video extensions to scan (default: mp4).")
    var extensions: String?

    // MARK: - Run

    mutating func run() async throws {
        // 1 — Resolve to absolute URL (normalise relative paths before any check)
        let resolvedURL = URL(fileURLWithPath: path).standardizedFileURL

        // 2 — Validate: must be a readable directory
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: resolvedURL.path, isDirectory: &isDir
        )
        guard exists, isDir.boolValue else {
            let envelope = VvxErrorEnvelope(error: VvxError(
                code:    .permissionDenied,
                message: exists
                    ? "ingest: path is not a directory: \(resolvedURL.path)"
                    : "ingest: directory not found: \(resolvedURL.path)",
                agentAction: "Supply a valid, readable directory path and retry."
            ))
            print(envelope.jsonString())
            throw ExitCode(VvxExitCode.forErrorCode(.permissionDenied))
        }

        // 3 — Parse comma-separated extensions (trim whitespace, lowercase)
        let extList: [String] = extensions.map {
            $0.split(separator: ",")
              .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
              .filter { !$0.isEmpty }
        } ?? ["mp4"]

        // 4 — Build config
        let config = IngestConfig(
            rootURL:      resolvedURL,
            dryRun:       dryRun,
            forceReindex: forceReindex,
            extensions:   extList
        )

        // 5 — Run engine; progress callback prints heartbeats to stderr
        let result = await IngestEngine.run(config: config, progress: ingestHeartbeat)
        print(result)

        // 6 — Non-zero exit when any line signals failure
        if result.contains("\"success\":false") {
            throw ExitCode(1)
        }
    }
}

// MARK: - Stderr progress heartbeat (free function — no captures, no isolation)

/// Formats one stderr heartbeat line per the spec (Step 9.5, item 11):
///   Normal:   `Scanning… N files checked, M indexed.`
///   Dry-run:  `DRY-RUN: Scanning… N files checked, M indexed.`
private func ingestHeartbeat(_ filesChecked: Int, _ indexed: Int, _ dryRun: Bool) {
    let msg  = "Scanning\u{2026} \(filesChecked) files checked, \(indexed) indexed."
    let line = dryRun ? "DRY-RUN: \(msg)" : msg
    Foundation.fputs(line + "\n", stderr)
}
