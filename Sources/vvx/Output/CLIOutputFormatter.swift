import Foundation
import VideoVortexCore

/// Formats CLI output following the strict separation rule:
///   stderr — all human-readable progress, banners, and status messages
///   stdout — all machine-readable output (JSON, transcript text, markdown)
///
/// This rule is enforced here so agent pipelines can always safely pipe stdout
/// without mixing it with progress noise.
public enum CLIOutputFormatter {

    // MARK: - Sense progress (→ stderr)

    public static func sensing(url: String) {
        fputs("Sensing \(url)...\n", stderr)
    }

    public static func senseMilestone(_ milestone: SenseMilestone) {
        fputs("  • \(milestone.label)\n", stderr)
    }

    public static func senseDone(elapsed: TimeInterval, transcriptPath: String?) {
        let secs = String(format: "%.1f", elapsed)
        if let path = transcriptPath {
            let display = path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            fputs("✓ Done in \(secs)s — transcript at \(display)\n", stderr)
        } else {
            fputs("✓ Done in \(secs)s — no transcript extracted\n", stderr)
        }
    }

    public static func senseFailed(_ message: String) {
        fputs("✗ Sense failed: \(message)\n", stderr)
    }

    // MARK: - Download progress (→ stderr)

    public static func preparing() {
        fputs("Preparing download...\n", stderr)
    }

    public static func progress(percent: Double, speed: String, eta: String) {
        let filled = Int(percent * 20)
        let bar    = String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)
        let line   = String(format: "\r[%@] %5.1f%% • %@ • ETA %@", bar, percent * 100, speed, eta)
        fputs(line, stderr)
    }

    public static func titleResolved(_ title: String) {
        fputs("\nTitle: \(title)\n", stderr)
    }

    public static func resolutionResolved(_ res: String) {
        fputs("Resolution: \(res)\n", stderr)
    }

    public static func retrying() {
        fputs("\nEngine refreshed — retrying download...\n", stderr)
    }

    public static func failed(_ message: String) {
        fputs("\n✗ Failed: \(message)\n", stderr)
    }

    // MARK: - Download success (→ stderr for banner, stdout for JSON/summary)

    /// Prints VideoMetadata as JSON to stdout (for agent pipelines).
    public static func printJSON(_ metadata: VideoMetadata) {
        print(metadata.jsonString())
    }

    /// Prints a human-readable completion summary to stderr.
    public static func printSummary(_ metadata: VideoMetadata) {
        fputs("\n✓ Target acquired: \(metadata.title)\n", stderr)
        fputs("  Platform:  \(metadata.platform ?? "Unknown")\n", stderr)
        if let res = metadata.resolution { fputs("  Quality:   \(res)\n", stderr) }
        if let dur = metadata.durationSeconds { fputs("  Duration:  \(formatDuration(dur))\n", stderr) }
        fputs("  File:      \(MediaStoragePaths.tildePath(for: URL(fileURLWithPath: metadata.outputPath)))\n", stderr)
        if !metadata.subtitlePaths.isEmpty {
            fputs("  Subtitles: \(metadata.subtitlePaths.count) .srt file(s)\n", stderr)
        }
        fputs("\n", stderr)
    }

    // MARK: - Error guidance (→ stderr)

    /// Prints agent recovery guidance after any error event.
    /// Always appends the doctor footer so agents learn to call it as a reflex.
    public static func printErrorGuidance(for error: VvxError) {
        if let action = error.agentAction {
            fputs("  Suggestion: \(action)\n", stderr)
        }
        fputs("  Run 'vvx doctor' for a full environment diagnosis.\n", stderr)
    }

    // MARK: - Engine messages (→ stderr)

    public static func engineNotFound() {
        fputs("""
        ✗  yt-dlp not found.

           Install it with your system package manager:

             macOS (Homebrew):  brew install yt-dlp
             All platforms:     pip install yt-dlp
             Direct binary:     https://github.com/yt-dlp/yt-dlp#installation

           After installing, re-run your command. Run 'vvx doctor' to verify.

        """, stderr)
    }

    public static func engineStatus(version: String?, path: String) {
        if let v = version {
            fputs("yt-dlp \(v) at \(path)\n", stderr)
        } else {
            fputs("yt-dlp at \(path) (version unknown)\n", stderr)
        }
    }

    // MARK: - Helpers

    static func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - fputs convenience for Swift strings

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
