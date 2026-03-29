import Foundation
import VideoVortexCore

/// Writes NDJSON (newline-delimited JSON) output for batch operations.
///
/// Each completed or failed URL emits exactly one JSON object to stdout,
/// terminated by a newline. Results stream as they complete — the caller
/// does not wait for the whole batch before seeing output.
///
/// stdout is the sole output channel. Progress banners go to stderr.
public enum NDJSONStreamer {

    // MARK: - Sense results

    /// Writes a SenseResult as a compact JSON line to stdout.
    public static func writeSenseResult(_ result: SenseResult) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(result),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }

    /// Writes a VvxError in the standard error envelope as a compact JSON line to stdout.
    public static func writeError(_ error: VvxError) {
        let envelope = VvxErrorEnvelope(error: error)
        let encoder  = JSONEncoder()
        guard let data = try? encoder.encode(envelope),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }

    // MARK: - Batch progress (→ stderr)

    /// Emits a per-URL completion line to stderr for human observers.
    public static func progressLine(index: Int, total: Int, title: String?, success: Bool) {
        let status = success ? "✓" : "✗"
        let label  = title ?? "…"
        fputs("[\(index)/\(total)] \(status) \(label)\n", stderr)
    }

    public static func batchStart(count: Int) {
        fputs("Processing \(count) URL\(count == 1 ? "" : "s")...\n", stderr)
    }

    public static func batchDone(succeeded: Int, failed: Int) {
        let total = succeeded + failed
        fputs("Done. \(succeeded)/\(total) succeeded\(failed > 0 ? ", \(failed) failed" : "").\n", stderr)
    }

    // MARK: - Sync progress (→ stderr)

    /// Per-URL completion line for `vvx sync`, where the total may not be known upfront.
    /// Uses `[i/N]` when `total` is supplied, and `[i]` when the playlist size is open-ended.
    public static func syncProgressLine(index: Int, total: Int?, title: String?, success: Bool) {
        let status = success ? "✓" : "✗"
        let label  = title ?? "…"
        if let total {
            fputs("[\(index)/\(total)] \(status) \(label)\n", stderr)
        } else {
            fputs("[\(index)] \(status) \(label)\n", stderr)
        }
    }

    /// Per-skipped-URL line for `vvx sync --incremental` — printed to stderr so the operator
    /// can see which videos were bypassed without polluting NDJSON stdout.
    public static func syncSkippedLine(url: String) {
        fputs("[skipped] \(url)\n", stderr)
    }

    /// Writes a compact NDJSON line to stdout for a URL that was skipped by `--incremental`.
    /// The title is intentionally omitted — we have not called yt-dlp yet for this URL,
    /// so fetching the title would defeat the purpose of skipping.
    public static func writeSyncSkipped(url: String) {
        let obj = _SyncSkippedLine(url: url)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(obj),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }

    /// Final summary line for `vvx sync` — printed to stderr after the TaskGroup drains.
    public static func syncDone(succeeded: Int, failed: Int, skipped: Int, indexed: Int) {
        let total = succeeded + failed + skipped
        var parts: [String] = ["\(succeeded) new"]
        if skipped > 0 { parts.append("\(skipped) skipped (already in library)") }
        if failed  > 0 { parts.append("\(failed) failed") }
        fputs("Done. \(parts.joined(separator: ", ")). \(total) total checked.\n", stderr)
    }
}

// MARK: - Private helpers

/// Encodable payload for a sync-skipped NDJSON line.
private struct _SyncSkippedLine: Encodable {
    let success: Bool   = true
    let skipped: Bool   = true
    let url:     String
    let reason:  String = "already_in_vault"
}

// MARK: - fputs convenience

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
