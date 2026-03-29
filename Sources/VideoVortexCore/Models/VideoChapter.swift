import Foundation

/// A single chapter marker extracted from a video's metadata.
///
/// Agents use chapters as a free table-of-contents — read the chapter titles,
/// identify the relevant section, then jump to that timestamp in the transcript
/// rather than ingesting the entire thing.
public struct VideoChapter: Codable, Sendable, Equatable {

    /// Chapter title as set by the creator.
    public let title: String

    /// Start time in seconds (from yt-dlp's `start_time` field).
    public let startTime: Double

    /// Human-readable start time ("0:00", "3:42", "1:04:30").
    public let startTimeFormatted: String

    /// End time in seconds: the next chapter's `startTime`, or the video's `durationSeconds`
    /// for the last chapter. `nil` when video duration is unknown and this is the final chapter.
    public let endTime: Double?

    /// Sum of `estimatedTokens` across all `TranscriptBlock`s in this chapter.
    /// `nil` when the video has no transcript or no blocks fall within this chapter.
    /// Convention: `nil` (not `0`) when chapters exist but this one has zero matching blocks.
    public let estimatedTokens: Int?

    public init(
        title: String,
        startTime: Double,
        endTime: Double? = nil,
        estimatedTokens: Int? = nil
    ) {
        self.title              = title
        self.startTime          = startTime
        self.startTimeFormatted = VideoChapter.format(seconds: startTime)
        self.endTime            = endTime
        self.estimatedTokens    = estimatedTokens
    }

    // MARK: - Formatting

    private static func format(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}
