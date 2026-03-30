import Foundation

// MARK: - MonologueSpan

/// A contiguous speech span identified by `StructuralAnalyzer.longestMonologue(blocks:maxGapSeconds:)`.
///
/// Two consecutive `StoredBlock` entries are considered part of the same span when
/// `blocks[n+1].startSeconds − blocks[n].endSeconds ≤ maxGapSeconds`.
public struct MonologueSpan: Sendable {
    /// Start time of the first block in the span.
    public let startSeconds:      Double
    /// End time of the last block in the span.
    public let endSeconds:        Double
    /// `endSeconds − startSeconds`.
    public let durationSeconds:   Double
    /// Number of SRT blocks merged into this span.
    public let blockCount:        Int
    /// First ~1,000 characters of concatenated block text.
    /// Sized for LLM evaluation in the Phase 3.6 two-step pipeline.
    public let transcriptExcerpt: String
}

// MARK: - DensitySpan

/// A high-density window identified by `StructuralAnalyzer.highDensityWindow(blocks:windowSeconds:)`.
///
/// Score = `wordCount / windowSeconds`. Two-pointer sliding window — O(n).
public struct DensitySpan: Sendable {
    /// `startSeconds` of the left-boundary block in the best window.
    public let startSeconds:      Double
    /// `min(startSeconds + windowSeconds, lastBlock.endSeconds)` — actual content end.
    public let endSeconds:        Double
    /// Total word count of blocks inside the window.
    public let wordCount:         Int
    /// `wordCount / windowSeconds`.
    public let wordsPerSecond:    Double
    /// First ~1,000 characters of concatenated block text in the window.
    /// Sized for LLM evaluation in the Phase 3.6 two-step pipeline.
    public let transcriptExcerpt: String
}

// MARK: - StructuralAnalyzer

/// Deterministic transcript structure analysis — no LLM, no network, no I/O.
///
/// Both functions are O(n) in block count and operate on `StoredBlock` arrays
/// returned by `VortexDB.blocksForVideo(videoId:)`, which are already ordered
/// by `startSeconds` ascending.
public enum StructuralAnalyzer {

    // MARK: - longestMonologue

    /// Find the longest contiguous monologue span in an ordered block list.
    ///
    /// Two consecutive blocks are merged into the same span when
    /// `blocks[n+1].startSeconds − blocks[n].endSeconds ≤ maxGapSeconds`.
    /// The `≤` (not `<`) means a gap exactly at the threshold keeps blocks together.
    ///
    /// - Parameters:
    ///   - blocks: Ordered by `startSeconds` ascending (as returned by `VortexDB.blocksForVideo`).
    ///   - maxGapSeconds: Maximum silence gap in seconds. Must be ≥ 0. Default 1.5 s covers
    ///     micro-pauses without splitting natural monologues; increase for slower speakers.
    /// - Returns: The single longest `MonologueSpan`, or `nil` when `blocks` is empty.
    public static func longestMonologue(
        blocks: [StoredBlock],
        maxGapSeconds: Double = 1.5
    ) -> MonologueSpan? {
        guard !blocks.isEmpty else { return nil }

        var bestSpan:  MonologueSpan?
        var spanStart  = blocks[0].startSeconds
        var spanEnd    = blocks[0].endSeconds
        var spanCount  = 1
        var spanParts: [String] = [blocks[0].text]

        for i in 1 ..< blocks.count {
            let gap = blocks[i].startSeconds - blocks[i - 1].endSeconds
            if gap <= maxGapSeconds {
                spanEnd = blocks[i].endSeconds
                spanCount += 1
                spanParts.append(blocks[i].text)
            } else {
                let dur = spanEnd - spanStart
                if bestSpan == nil || dur > bestSpan!.durationSeconds {
                    bestSpan = MonologueSpan(
                        startSeconds:      spanStart,
                        endSeconds:        spanEnd,
                        durationSeconds:   dur,
                        blockCount:        spanCount,
                        transcriptExcerpt: String(spanParts.joined(separator: " ").prefix(1000))
                    )
                }
                spanStart  = blocks[i].startSeconds
                spanEnd    = blocks[i].endSeconds
                spanCount  = 1
                spanParts  = [blocks[i].text]
            }
        }

        // Flush the final span.
        let finalDur = spanEnd - spanStart
        if bestSpan == nil || finalDur > bestSpan!.durationSeconds {
            bestSpan = MonologueSpan(
                startSeconds:      spanStart,
                endSeconds:        spanEnd,
                durationSeconds:   finalDur,
                blockCount:        spanCount,
                transcriptExcerpt: String(spanParts.joined(separator: " ").prefix(1000))
            )
        }
        return bestSpan
    }

    // MARK: - highDensityWindow

    /// Find the highest words-per-second window in an ordered block list.
    ///
    /// Uses a two-pointer sliding window. Score = `totalWordsInWindow / windowSeconds`.
    /// Per-block word count is computed as `text.split(whereSeparator: \.isWhitespace).count`,
    /// matching the `TranscriptBlock.wordCount` heuristic.
    ///
    /// - Parameters:
    ///   - blocks: Ordered by `startSeconds` ascending.
    ///   - windowSeconds: Width of the analysis window in seconds. Must be > 0. Default 60.0 s
    ///     captures a complete exchange; use 30.0 for tight highlight-reel clips.
    /// - Returns: The single highest-density `DensitySpan`, or `nil` when `blocks` is empty
    ///   or `windowSeconds ≤ 0`.
    public static func highDensityWindow(
        blocks: [StoredBlock],
        windowSeconds: Double = 60.0
    ) -> DensitySpan? {
        guard !blocks.isEmpty, windowSeconds > 0 else { return nil }

        var left         = 0
        var currentWords = 0
        var bestSpan:    DensitySpan?

        for right in 0 ..< blocks.count {
            let rightWords = wordCount(blocks[right].text)
            currentWords += rightWords

            // Shrink window from the left while it exceeds `windowSeconds`.
            while blocks[right].startSeconds - blocks[left].startSeconds > windowSeconds {
                currentWords -= wordCount(blocks[left].text)
                left += 1
            }

            let wps = Double(currentWords) / windowSeconds
            if bestSpan == nil || wps > bestSpan!.wordsPerSecond {
                let winEnd = min(blocks[left].startSeconds + windowSeconds,
                                 blocks[right].endSeconds)
                let text   = blocks[left ... right].map(\.text).joined(separator: " ")
                bestSpan = DensitySpan(
                    startSeconds:      blocks[left].startSeconds,
                    endSeconds:        winEnd,
                    wordCount:         currentWords,
                    wordsPerSecond:    wps,
                    transcriptExcerpt: String(text.prefix(1000))
                )
            }
        }
        return bestSpan
    }

    // MARK: - Private helpers

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
