import Foundation

// MARK: - MonologueSpan

/// A contiguous speech span identified by `StructuralAnalyzer.longestMonologue(blocks:maxGapSeconds:chapters:)`.
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
    /// Title of the chapter the span's first block belongs to.
    /// `nil` when chapter metadata is absent (no chapters on this video, or `vvx reindex` needed).
    public let chapterTitle:      String?
    /// Zero-based index into the video's chapters array.
    public let chapterIndex:      Int?
    /// `true` when the span's blocks span more than one chapter boundary.
    /// When `true`, `chapterTitle` reflects the opening chapter.
    public let isMultiChapter:    Bool
}

// MARK: - DensitySpan

/// A high-density window identified by `StructuralAnalyzer.highDensityWindow(blocks:windowSeconds:chapters:)`.
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
    /// Title of the chapter the window's left-boundary block belongs to.
    public let chapterTitle:      String?
    /// Zero-based index into the video's chapters array.
    public let chapterIndex:      Int?
    /// `true` when the window's blocks span more than one chapter boundary.
    public let isMultiChapter:    Bool
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
    ///   - chapters: The video's chapter array for context derivation. Default empty array
    ///     preserves backward compatibility — callers that do not pass chapters receive
    ///     `chapterTitle: nil`, `chapterIndex: nil`, `isMultiChapter: false`.
    /// - Returns: The single longest `MonologueSpan`, or `nil` when `blocks` is empty.
    public static func longestMonologue(
        blocks:        [StoredBlock],
        maxGapSeconds: Double = 1.5,
        chapters:      [VideoChapter] = []
    ) -> MonologueSpan? {
        guard !blocks.isEmpty else { return nil }

        var bestSpan:       MonologueSpan?
        var spanStart       = blocks[0].startSeconds
        var spanEnd         = blocks[0].endSeconds
        var spanCount       = 1
        var spanParts:      [String]      = [blocks[0].text]
        var spanBlocks:     [StoredBlock] = [blocks[0]]
        var firstBlockOfSpan              = blocks[0]

        for i in 1 ..< blocks.count {
            let gap = blocks[i].startSeconds - blocks[i - 1].endSeconds
            if gap <= maxGapSeconds {
                spanEnd = blocks[i].endSeconds
                spanCount += 1
                spanParts.append(blocks[i].text)
                spanBlocks.append(blocks[i])
            } else {
                let dur = spanEnd - spanStart
                if bestSpan == nil || dur > bestSpan!.durationSeconds {
                    let (chTitle, chIdx, isMulti) = resolveChapterContext(
                        anchorBlock: firstBlockOfSpan,
                        blocks:      spanBlocks,
                        chapters:    chapters
                    )
                    bestSpan = MonologueSpan(
                        startSeconds:      spanStart,
                        endSeconds:        spanEnd,
                        durationSeconds:   dur,
                        blockCount:        spanCount,
                        transcriptExcerpt: String(spanParts.joined(separator: " ").prefix(1000)),
                        chapterTitle:      chTitle,
                        chapterIndex:      chIdx,
                        isMultiChapter:    isMulti
                    )
                }
                spanStart        = blocks[i].startSeconds
                spanEnd          = blocks[i].endSeconds
                spanCount        = 1
                spanParts        = [blocks[i].text]
                spanBlocks       = [blocks[i]]
                firstBlockOfSpan = blocks[i]
            }
        }

        // Flush the final span.
        let finalDur = spanEnd - spanStart
        if bestSpan == nil || finalDur > bestSpan!.durationSeconds {
            let (chTitle, chIdx, isMulti) = resolveChapterContext(
                anchorBlock: firstBlockOfSpan,
                blocks:      spanBlocks,
                chapters:    chapters
            )
            bestSpan = MonologueSpan(
                startSeconds:      spanStart,
                endSeconds:        spanEnd,
                durationSeconds:   finalDur,
                blockCount:        spanCount,
                transcriptExcerpt: String(spanParts.joined(separator: " ").prefix(1000)),
                chapterTitle:      chTitle,
                chapterIndex:      chIdx,
                isMultiChapter:    isMulti
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
    ///   - chapters: The video's chapter array for context derivation. Default empty array
    ///     preserves backward compatibility.
    /// - Returns: The single highest-density `DensitySpan`, or `nil` when `blocks` is empty
    ///   or `windowSeconds ≤ 0`.
    public static func highDensityWindow(
        blocks:        [StoredBlock],
        windowSeconds: Double = 60.0,
        chapters:      [VideoChapter] = []
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
                let winEnd       = min(blocks[left].startSeconds + windowSeconds,
                                       blocks[right].endSeconds)
                let windowBlocks = Array(blocks[left ... right])
                let text         = windowBlocks.map(\.text).joined(separator: " ")
                let (chTitle, chIdx, isMulti) = resolveChapterContext(
                    anchorBlock: blocks[left],
                    blocks:      windowBlocks,
                    chapters:    chapters
                )
                bestSpan = DensitySpan(
                    startSeconds:      blocks[left].startSeconds,
                    endSeconds:        winEnd,
                    wordCount:         currentWords,
                    wordsPerSecond:    wps,
                    transcriptExcerpt: String(text.prefix(1000)),
                    chapterTitle:      chTitle,
                    chapterIndex:      chIdx,
                    isMultiChapter:    isMulti
                )
            }
        }
        return bestSpan
    }

    // MARK: - Private helpers

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Resolve chapter title and multi-chapter flag from a slice of StoredBlocks.
    ///
    /// - Parameters:
    ///   - anchorBlock: The block whose `chapterIndex` identifies the opening chapter
    ///                  (first block for monologue; left-boundary block for density window).
    ///   - blocks: All blocks in the span/window (used for multi-chapter detection).
    ///   - chapters: The video's chapter array.
    private static func resolveChapterContext(
        anchorBlock: StoredBlock,
        blocks:      [StoredBlock],
        chapters:    [VideoChapter]
    ) -> (title: String?, index: Int?, isMulti: Bool) {
        guard !chapters.isEmpty else { return (nil, nil, false) }
        guard let anchorIdx = anchorBlock.chapterIndex else { return (nil, nil, false) }
        guard anchorIdx >= 0, anchorIdx < chapters.count else { return (nil, nil, false) }
        let title   = chapters[anchorIdx].title
        let isMulti = blocks.contains { block in
            guard let ci = block.chapterIndex else { return false }
            return ci != anchorIdx
        }
        return (title, anchorIdx, isMulti)
    }
}
