import Foundation

/// Re-times transcript blocks relative to a padded clip window, producing
/// a `.srt` file whose timeline starts at `00:00:00` matching the extracted MP4.
///
/// **Whole-cue rule (locked):** Any block that *overlaps* the padded window is kept in
/// its entirety — no mathematical mid-cue slicing. Partial lines ("artifici…") are a
/// worse editorial experience than a cue that starts slightly before the clip's start frame.
///
/// Returns `nil` when no blocks overlap, so callers omit the file entirely rather than
/// writing an empty `.srt` that would cause NLEs to create phantom caption tracks.
public enum SRTRetimer {

    // MARK: - Public API

    /// Build re-timed SRT content from stored transcript blocks.
    ///
    /// - Parameters:
    ///   - blocks:      All transcript blocks for the video, ordered by start time.
    ///                  Use `VortexDB.blocksForVideo(videoId:)`.
    ///   - paddedStart: Start of the extracted MP4 clip in seconds (after pad is applied).
    ///   - paddedEnd:   End of the extracted MP4 clip in seconds (after pad is applied).
    /// - Returns: Formatted SRT file content (UTF-8 string), or `nil` if no blocks
    ///   overlap the window — callers **must not** write a file when `nil` is returned.
    public static func retimed(
        blocks: [StoredBlock],
        paddedStart: Double,
        paddedEnd: Double
    ) -> String? {
        let clipDuration = paddedEnd - paddedStart
        var lines: [String] = []
        var outIndex = 1

        for block in blocks {
            guard let blockEnd = parseEndSeconds(block.endTime) else { continue }

            // Whole-cue overlap: include block if any part intersects [paddedStart, paddedEnd).
            guard blockEnd > paddedStart && block.startSeconds < paddedEnd else { continue }

            // Rebase timestamps to clip timeline (paddedStart = 00:00:00).
            let newStart = max(0, block.startSeconds - paddedStart)
            let newEnd   = min(clipDuration, blockEnd - paddedStart)

            lines.append(String(outIndex))
            lines.append("\(srtTimestamp(newStart)) --> \(srtTimestamp(newEnd))")
            lines.append(block.text)
            lines.append("")   // blank line between blocks
            outIndex += 1
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Formatting (internal, exposed for tests)

    /// Format decimal seconds as an SRT timestamp: `HH:MM:SS,mmm`.
    static func srtTimestamp(_ seconds: Double) -> String {
        let totalMs  = Int((seconds * 1000).rounded(.toNearestOrAwayFromZero))
        let ms       = totalMs % 1000
        let totalSec = totalMs / 1000
        let sec      = totalSec % 60
        let totalMin = totalSec / 60
        let min      = totalMin % 60
        let hours    = totalMin / 60
        return String(format: "%02d:%02d:%02d,%03d", hours, min, sec, ms)
    }

    // MARK: - Helpers

    private static func parseEndSeconds(_ srtTimestamp: String) -> Double? {
        GatherPathNaming.parseSRTTimestampToSeconds(srtTimestamp)
    }
}
