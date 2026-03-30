import XCTest
@testable import VideoVortexCore

// MARK: - StructuralAnalyzerTests

final class StructuralAnalyzerTests: XCTestCase {

    // MARK: - longestMonologue

    func testLongestMonologue_empty() {
        XCTAssertNil(StructuralAnalyzer.longestMonologue(blocks: []))
    }

    func testLongestMonologue_single() {
        let blocks = [block(start: 0, end: 5, text: "Hello world")]
        let span = StructuralAnalyzer.longestMonologue(blocks: blocks)
        XCTAssertNotNil(span)
        XCTAssertEqual(span?.durationSeconds, 5.0)
        XCTAssertEqual(span?.blockCount, 1)
        XCTAssertEqual(span?.startSeconds, 0.0)
        XCTAssertEqual(span?.endSeconds, 5.0)
    }

    func testLongestMonologue_allContiguous() {
        // Three blocks with gaps well under the threshold — should merge into one span.
        let blocks = [
            block(start: 0.0, end: 3.0, text: "Block one"),
            block(start: 3.5, end: 6.5, text: "Block two"),
            block(start: 7.0, end: 10.0, text: "Block three")
        ]
        let span = StructuralAnalyzer.longestMonologue(blocks: blocks, maxGapSeconds: 1.5)
        XCTAssertEqual(span?.blockCount, 3)
        XCTAssertEqual(span?.startSeconds, 0.0)
        XCTAssertEqual(span?.endSeconds, 10.0)
        XCTAssertEqual(span?.durationSeconds, 10.0)
    }

    func testLongestMonologue_splitByGap() {
        // Gap of 5 s between blocks 2 and 3 — should split. Second span is longer.
        let blocks = [
            block(start: 0.0,  end: 2.0,  text: "A"),      // span 1
            block(start: 3.0,  end: 5.0,  text: "B"),      // span 1
            block(start: 10.0, end: 12.0, text: "C"),      // span 2
            block(start: 13.0, end: 15.0, text: "D"),      // span 2
            block(start: 16.0, end: 20.0, text: "E")       // span 2
        ]
        let span = StructuralAnalyzer.longestMonologue(blocks: blocks, maxGapSeconds: 1.5)
        // Span 1: duration = 5 - 0 = 5. Span 2: duration = 20 - 10 = 10. Span 2 wins.
        XCTAssertEqual(span?.blockCount, 3)
        XCTAssertEqual(span?.startSeconds, 10.0)
        XCTAssertEqual(span?.endSeconds, 20.0)
        XCTAssertEqual(span?.durationSeconds ?? 0, 10.0, accuracy: 0.01)
    }

    func testLongestMonologue_exactGapThresholdIsContiguous() {
        // Gap == maxGapSeconds: blocks should be kept together (≤ check).
        let blocks = [
            block(start: 0.0, end: 3.0, text: "A"),
            block(start: 4.5, end: 7.0, text: "B")   // gap = 1.5 exactly
        ]
        let span = StructuralAnalyzer.longestMonologue(blocks: blocks, maxGapSeconds: 1.5)
        XCTAssertEqual(span?.blockCount, 2)
    }

    func testLongestMonologue_excerptTruncatedAt1000() {
        let words = Array(repeating: "word", count: 300).joined(separator: " ")  // > 1000 chars
        let blocks = [block(start: 0, end: 10, text: words)]
        let span = StructuralAnalyzer.longestMonologue(blocks: blocks)
        XCTAssertLessThanOrEqual(span?.transcriptExcerpt.count ?? 0, 1000)
    }

    func testLongestMonologue_firstSpanWinsOnTie() {
        // Two spans of equal duration — the first one (lower startSeconds) should win
        // because we only update `bestSpan` when strictly greater.
        let blocks = [
            block(start: 0.0, end: 5.0, text: "A"),    // span 1: dur = 5
            block(start: 10.0, end: 15.0, text: "B")   // span 2: dur = 5
        ]
        let span = StructuralAnalyzer.longestMonologue(blocks: blocks, maxGapSeconds: 1.5)
        XCTAssertEqual(span?.startSeconds, 0.0, "First span wins on tie")
    }

    // MARK: - highDensityWindow

    func testHighDensityWindow_empty() {
        XCTAssertNil(StructuralAnalyzer.highDensityWindow(blocks: []))
    }

    func testHighDensityWindow_zeroWindowReturnsNil() {
        let blocks = [block(start: 0, end: 5, text: "hello")]
        XCTAssertNil(StructuralAnalyzer.highDensityWindow(blocks: blocks, windowSeconds: 0))
    }

    func testHighDensityWindow_singleBlock() {
        let blocks = [block(start: 0, end: 5, text: "one two three")]
        let span = StructuralAnalyzer.highDensityWindow(blocks: blocks, windowSeconds: 60.0)
        XCTAssertNotNil(span)
        XCTAssertEqual(span?.wordCount, 3)
        XCTAssertGreaterThan(span?.wordsPerSecond ?? 0, 0)
    }

    func testHighDensityWindow_picksHighestDensityWindow() {
        // Dense cluster: blocks 3-5 (start 120-178) in a 60 s window
        let blocks = [
            block(start: 0.0,   end: 3.0,   text: "one"),           // 1 word  — sparse
            block(start: 60.0,  end: 63.0,  text: "two"),           // 1 word  — sparse
            block(start: 120.0, end: 123.0, text: Array(repeating: "dense", count: 30).joined(separator: " ")),  // 30 words
            block(start: 140.0, end: 143.0, text: Array(repeating: "dense", count: 30).joined(separator: " ")),  // 30 words
            block(start: 160.0, end: 163.0, text: Array(repeating: "dense", count: 30).joined(separator: " ")),  // 30 words
        ]
        let span = StructuralAnalyzer.highDensityWindow(blocks: blocks, windowSeconds: 60.0)
        // The dense cluster starts at 120.0
        XCTAssertEqual(span?.startSeconds, 120.0)
        XCTAssertEqual(span?.wordCount, 90)
    }

    func testHighDensityWindow_excerptTruncatedAt1000() {
        let longText = Array(repeating: "x", count: 600).joined(separator: " ")
        let blocks = [block(start: 0, end: 60, text: longText)]
        let span = StructuralAnalyzer.highDensityWindow(blocks: blocks, windowSeconds: 60.0)
        XCTAssertLessThanOrEqual(span?.transcriptExcerpt.count ?? 0, 1000)
    }

    func testHighDensityWindow_wordsPerSecondCalculation() {
        let blocks = [
            block(start: 0.0, end: 5.0, text: "one two three four five six")  // 6 words
        ]
        let span = StructuralAnalyzer.highDensityWindow(blocks: blocks, windowSeconds: 30.0)
        // 6 words / 30 s = 0.2 wps
        XCTAssertEqual(span?.wordsPerSecond ?? 0, 6.0 / 30.0, accuracy: 0.001)
    }

    // MARK: - Chapter context — longestMonologue

    func testLongestMonologue_chapterAssigned() {
        let chapters = [
            VideoChapter(title: "Introduction", startTime: 0),
            VideoChapter(title: "The AGI Debate", startTime: 10),
            VideoChapter(title: "Safety", startTime: 50)
        ]
        let blocks = [
            block(start: 10, end: 20, text: "AGI is coming", chapterIndex: 1),
            block(start: 21, end: 30, text: "faster than expected", chapterIndex: 1)
        ]
        let span = StructuralAnalyzer.longestMonologue(blocks: blocks, maxGapSeconds: 5.0, chapters: chapters)
        XCTAssertEqual(span?.chapterTitle, "The AGI Debate")
        XCTAssertEqual(span?.chapterIndex, 1)
        XCTAssertEqual(span?.isMultiChapter, false)
    }

    func testLongestMonologue_nilChapterOnFirstBlock() {
        let chapters = [
            VideoChapter(title: "Introduction", startTime: 0)
        ]
        let blocks = [
            block(start: 0, end: 5, text: "Hello", chapterIndex: nil),
            block(start: 5.5, end: 10, text: "World", chapterIndex: 0)
        ]
        let span = StructuralAnalyzer.longestMonologue(blocks: blocks, maxGapSeconds: 2.0, chapters: chapters)
        XCTAssertNil(span?.chapterTitle)
        XCTAssertNil(span?.chapterIndex)
        XCTAssertEqual(span?.isMultiChapter, false)
    }

    func testLongestMonologue_isMultiChapter() {
        let chapters = [
            VideoChapter(title: "Chapter One", startTime: 0),
            VideoChapter(title: "Chapter Two", startTime: 10)
        ]
        let blocks = [
            block(start: 0, end: 5, text: "Intro text", chapterIndex: 0),
            block(start: 5.5, end: 10, text: "More intro", chapterIndex: 0),
            block(start: 10.5, end: 15, text: "Chapter two text", chapterIndex: 1)
        ]
        let span = StructuralAnalyzer.longestMonologue(blocks: blocks, maxGapSeconds: 2.0, chapters: chapters)
        XCTAssertEqual(span?.chapterTitle, "Chapter One")
        XCTAssertEqual(span?.chapterIndex, 0)
        XCTAssertEqual(span?.isMultiChapter, true)
    }

    func testLongestMonologue_emptyChapters() {
        let blocks = [
            block(start: 0, end: 5, text: "Hello", chapterIndex: 2)
        ]
        let span = StructuralAnalyzer.longestMonologue(blocks: blocks, chapters: [])
        XCTAssertNil(span?.chapterTitle)
        XCTAssertNil(span?.chapterIndex)
        XCTAssertEqual(span?.isMultiChapter, false)
    }

    func testLongestMonologue_backwardCompatNilChapters() {
        // Calling without chapters parameter should compile and return nil chapter fields.
        let blocks = [block(start: 0, end: 5, text: "Hello")]
        let span = StructuralAnalyzer.longestMonologue(blocks: blocks)
        XCTAssertNil(span?.chapterTitle)
        XCTAssertNil(span?.chapterIndex)
        XCTAssertEqual(span?.isMultiChapter, false)
    }

    // MARK: - Chapter context — highDensityWindow

    func testHighDensityWindow_chapterAssigned() {
        let chapters = [
            VideoChapter(title: "Existential Risks", startTime: 0)
        ]
        let blocks = [
            block(start: 0, end: 5, text: Array(repeating: "word", count: 20).joined(separator: " "), chapterIndex: 0)
        ]
        let span = StructuralAnalyzer.highDensityWindow(blocks: blocks, windowSeconds: 60.0, chapters: chapters)
        XCTAssertEqual(span?.chapterTitle, "Existential Risks")
        XCTAssertEqual(span?.chapterIndex, 0)
        XCTAssertEqual(span?.isMultiChapter, false)
    }

    func testHighDensityWindow_crossChapterWindow() {
        let chapters = [
            VideoChapter(title: "Chapter A", startTime: 0),
            VideoChapter(title: "Chapter B", startTime: 10)
        ]
        let blocks = [
            block(start: 0, end: 5, text: Array(repeating: "w", count: 50).joined(separator: " "), chapterIndex: 0),
            block(start: 5.5, end: 10, text: Array(repeating: "w", count: 50).joined(separator: " "), chapterIndex: 0),
            block(start: 10.5, end: 15, text: Array(repeating: "w", count: 50).joined(separator: " "), chapterIndex: 1)
        ]
        let span = StructuralAnalyzer.highDensityWindow(blocks: blocks, windowSeconds: 30.0, chapters: chapters)
        // Left boundary is block 0 (chapter 0); window includes chapter 1 → isMultiChapter.
        XCTAssertEqual(span?.chapterTitle, "Chapter A")
        XCTAssertEqual(span?.isMultiChapter, true)
    }

    func testHighDensityWindow_nilAnchorChapter() {
        let chapters = [
            VideoChapter(title: "Intro", startTime: 0)
        ]
        let blocks = [
            block(start: 0, end: 5, text: "hello world", chapterIndex: nil)
        ]
        let span = StructuralAnalyzer.highDensityWindow(blocks: blocks, windowSeconds: 60.0, chapters: chapters)
        XCTAssertNil(span?.chapterTitle)
        XCTAssertEqual(span?.isMultiChapter, false)
    }

    func testHighDensityWindow_emptyChapters() {
        let blocks = [block(start: 0, end: 5, text: "hello world", chapterIndex: 0)]
        let span = StructuralAnalyzer.highDensityWindow(blocks: blocks, chapters: [])
        XCTAssertNil(span?.chapterTitle)
        XCTAssertNil(span?.chapterIndex)
        XCTAssertEqual(span?.isMultiChapter, false)
    }

    func testHighDensityWindow_backwardCompatNilChapters() {
        let blocks = [block(start: 0, end: 5, text: "hello world")]
        let span = StructuralAnalyzer.highDensityWindow(blocks: blocks)
        XCTAssertNil(span?.chapterTitle)
        XCTAssertNil(span?.chapterIndex)
        XCTAssertEqual(span?.isMultiChapter, false)
    }

    // MARK: - Helpers

    private func block(start: Double, end: Double, text: String, chapterIndex: Int? = nil) -> StoredBlock {
        StoredBlock(
            startTime:    timestampString(start),
            endTime:      timestampString(end),
            startSeconds: start,
            endSeconds:   end,
            text:         text,
            chapterIndex: chapterIndex
        )
    }

    private func timestampString(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d,000", h, m, s)
    }
}
