import Foundation

/// A single timestamped, cleaned subtitle block included inline in a `SenseResult`.
///
/// Blocks are the primary transcript surface for agents. Use `chapterIndex` to
/// filter blocks by chapter without any floating-point timestamp arithmetic:
/// ```swift
/// let chapterBlocks = result.transcriptBlocks.filter { $0.chapterIndex == 2 }
/// ```
///
/// Token estimation: `estimatedTokens = wordCount × 1.3` (English-friendly approximation).
/// For strict budgets, tokenise `text` directly or scale `wordCount` with your own ratio.
public struct TranscriptBlock: Codable, Sendable, Equatable {

    /// Sequential block number from the source SRT file (1-based, as written by yt-dlp).
    public let index: Int

    /// Start time in decimal seconds.
    public let startSeconds: Double

    /// End time in decimal seconds.
    public let endSeconds: Double

    /// Cleaned subtitle text: HTML entities decoded, timing tags stripped, whitespace normalised.
    public let text: String

    /// Word count of `text` (split on whitespace).
    /// Ground truth for custom tokenizers — use when `estimatedTokens` is not precise enough.
    public let wordCount: Int

    /// Estimated token count using the formula `wordCount × 1.3`.
    /// Approximate; diverges for non-English, code-heavy, and CJK content.
    public let estimatedTokens: Int

    /// Zero-based index into `SenseResult.chapters` for the chapter this block belongs to.
    /// `nil` when the video has no chapter markers.
    public let chapterIndex: Int?

    public init(
        index: Int,
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        wordCount: Int,
        estimatedTokens: Int,
        chapterIndex: Int?
    ) {
        self.index           = index
        self.startSeconds    = startSeconds
        self.endSeconds      = endSeconds
        self.text            = text
        self.wordCount       = wordCount
        self.estimatedTokens = estimatedTokens
        self.chapterIndex    = chapterIndex
    }
}
