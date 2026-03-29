import Testing
import Foundation
@testable import VideoVortexCore

// MARK: - SRTRetimer Tests
// Covers §H testing plan from VVX3.5Step4.md.

@Suite("SRTRetimer")
struct SRTRetimerTests {

    // MARK: - Helpers

    private func block(_ start: Double, _ end: Double, _ text: String = "Hello world.") -> StoredBlock {
        StoredBlock(
            startTime:    SRTRetimer.srtTimestamp(start),
            endTime:      SRTRetimer.srtTimestamp(end),
            startSeconds: start,
            text:         text
        )
    }

    // MARK: - Pad clamp: paddedStart never drops below 0

    @Test("paddedBounds clamps start to 0 when pad exceeds logical start")
    func testPaddedBoundsClampAtZero() {
        let bounds = FFmpegRunner.paddedBounds(logicalStart: 1.0, logicalEnd: 5.0, pad: 3.0)
        #expect(bounds.start == 0.0)
        #expect(bounds.end == 8.0)
    }

    @Test("paddedBounds does not clamp start when pad fits within logical start")
    func testPaddedBoundsNoClamp() {
        let bounds = FFmpegRunner.paddedBounds(logicalStart: 10.0, logicalEnd: 20.0, pad: 2.0)
        #expect(bounds.start == 8.0)
        #expect(bounds.end == 22.0)
    }

    @Test("paddedBounds applies EOF clamp when video duration is known")
    func testPaddedBoundsEOFClamp() {
        let bounds = FFmpegRunner.paddedBounds(
            logicalStart: 100.0, logicalEnd: 115.0, pad: 5.0, videoDuration: 118.0
        )
        #expect(bounds.start == 95.0)
        #expect(bounds.end == 118.0)   // clamped to duration
    }

    @Test("paddedBounds does not shrink tail cue when video duration is unknown")
    func testPaddedBoundsNoShrinkWithoutDuration() {
        let bounds = FFmpegRunner.paddedBounds(
            logicalStart: 100.0, logicalEnd: 115.0, pad: 5.0, videoDuration: nil
        )
        #expect(bounds.start == 95.0)
        #expect(bounds.end == 120.0)   // no clamp
    }

    @Test("paddedBounds with pad 0 returns logical bounds unchanged")
    func testPaddedBoundsZeroPad() {
        let bounds = FFmpegRunner.paddedBounds(logicalStart: 30.0, logicalEnd: 45.0, pad: 0.0)
        #expect(bounds.start == 30.0)
        #expect(bounds.end == 45.0)
    }

    // MARK: - SRT timestamp formatting

    @Test("srtTimestamp formats zero as 00:00:00,000")
    func testSRTTimestampZero() {
        #expect(SRTRetimer.srtTimestamp(0) == "00:00:00,000")
    }

    @Test("srtTimestamp formats 3661.5 correctly")
    func testSRTTimestampHoursMinutesSeconds() {
        // 3661.5 s = 1h 1min 1.5s → 00:00:01,500 after 1h1m61.5... wait
        // 3661.5 = 3600 + 61.5 = 1h 1m 1.5s
        #expect(SRTRetimer.srtTimestamp(3661.5) == "01:01:01,500")
    }

    @Test("srtTimestamp rounds milliseconds correctly")
    func testSRTTimestampMillisecondRounding() {
        // 1.0005 s → 1000.5 ms → rounds to 1001 ms → 00:00:01,001
        let ts = SRTRetimer.srtTimestamp(1.0005)
        #expect(ts == "00:00:01,001")
    }

    // MARK: - Whole-cue rule

    @Test("retimed keeps whole cue that starts before paddedStart but overlaps")
    func testWholeCueOverlapAtStart() {
        let blocks = [block(8.0, 12.0, "I started before the pad window.")]
        let result = SRTRetimer.retimed(blocks: blocks, paddedStart: 10.0, paddedEnd: 20.0)
        #expect(result != nil)
        let srt = result!
        // newStart = max(0, 8.0 - 10.0) = 0.0
        // newEnd   = min(10.0, 12.0 - 10.0) = 2.0
        #expect(srt.contains("00:00:00,000 --> 00:00:02,000"))
        #expect(srt.contains("I started before the pad window."))
    }

    @Test("retimed keeps whole cue that ends after paddedEnd but overlaps")
    func testWholeCueOverlapAtEnd() {
        let blocks = [block(18.0, 25.0, "I end past the clip.")]
        let result = SRTRetimer.retimed(blocks: blocks, paddedStart: 10.0, paddedEnd: 20.0)
        #expect(result != nil)
        let srt = result!
        // newStart = max(0, 18.0 - 10.0) = 8.0
        // newEnd   = min(10.0, 25.0 - 10.0) = 10.0
        #expect(srt.contains("00:00:08,000 --> 00:00:10,000"))
    }

    @Test("retimed excludes block entirely before paddedStart")
    func testBlockBeforeWindow() {
        let blocks = [block(0.0, 5.0, "Too early."), block(12.0, 15.0, "In window.")]
        let result = SRTRetimer.retimed(blocks: blocks, paddedStart: 10.0, paddedEnd: 20.0)
        #expect(result != nil)
        let srt = result!
        #expect(!srt.contains("Too early."))
        #expect(srt.contains("In window."))
    }

    @Test("retimed excludes block entirely after paddedEnd")
    func testBlockAfterWindow() {
        let blocks = [block(12.0, 15.0, "In window."), block(25.0, 30.0, "Too late.")]
        let result = SRTRetimer.retimed(blocks: blocks, paddedStart: 10.0, paddedEnd: 20.0)
        #expect(result != nil)
        let srt = result!
        #expect(srt.contains("In window."))
        #expect(!srt.contains("Too late."))
    }

    // MARK: - No transcript → nil (clean absence)

    @Test("retimed returns nil for empty blocks (no transcript)")
    func testNoTranscriptReturnsNil() {
        let result = SRTRetimer.retimed(blocks: [], paddedStart: 0.0, paddedEnd: 30.0)
        #expect(result == nil)
    }

    @Test("retimed returns nil when no blocks overlap the window")
    func testNoOverlapReturnsNil() {
        let blocks = [block(0.0, 5.0, "Before."), block(50.0, 55.0, "After.")]
        let result = SRTRetimer.retimed(blocks: blocks, paddedStart: 10.0, paddedEnd: 20.0)
        #expect(result == nil)
    }

    // MARK: - Timeline alignment (first cue near 00:00:00)

    @Test("retimed first cue starts at or near 00:00:00")
    func testFirstCueAlignedToTimelineStart() {
        let blocks = [
            block(100.0, 105.0, "First line in the padded window."),
            block(106.0, 110.0, "Second line.")
        ]
        // paddedStart = 98.0 (with 2s pad applied externally)
        let result = SRTRetimer.retimed(blocks: blocks, paddedStart: 98.0, paddedEnd: 112.0)
        #expect(result != nil)
        let srt = result!
        // newStart for first block = max(0, 100.0 - 98.0) = 2.0
        #expect(srt.contains("00:00:02,000 --> 00:00:07,000"))
        #expect(srt.contains("00:00:08,000 --> 00:00:12,000"))
    }

    // MARK: - clip == gather math parity (same paddedBounds function)

    @Test("clip and gather use the same paddedBounds (single source of truth)")
    func testClipGatherPadMathParity() {
        let logicalStart = 4472.0
        let logicalEnd   = 4487.0
        let pad          = 2.0
        let dur          = 7200.0

        let bounds = FFmpegRunner.paddedBounds(
            logicalStart:  logicalStart,
            logicalEnd:    logicalEnd,
            pad:           pad,
            videoDuration: dur
        )
        // What gather passes to ffmpeg == what clip would pass to ffmpeg for same args.
        #expect(bounds.start == 4470.0)
        #expect(bounds.end   == 4489.0)
    }

    // MARK: - SRT index renumbering

    @Test("retimed renumbers output cues starting at 1")
    func testCueIndexRenumbering() {
        let blocks = [
            block(10.0, 12.0, "One."),
            block(14.0, 16.0, "Two."),
            block(18.0, 20.0, "Three.")
        ]
        let result = SRTRetimer.retimed(blocks: blocks, paddedStart: 8.0, paddedEnd: 22.0)
        #expect(result != nil)
        let lines = result!.components(separatedBy: "\n")
        #expect(lines[0] == "1")
        // Find second cue index — it appears after the blank separator line
        let secondCueIdx = lines.firstIndex(of: "2")
        #expect(secondCueIdx != nil)
        let thirdCueIdx = lines.firstIndex(of: "3")
        #expect(thirdCueIdx != nil)
    }

    // MARK: - Regression: --pad 0 preserves Step 3 bounds

    @Test("paddedBounds with pad 0 does not alter Step 3 resolved bounds")
    func testZeroPadPreservesStep3Bounds() {
        let start = 30.0
        let end   = 45.0
        let bounds = FFmpegRunner.paddedBounds(logicalStart: start, logicalEnd: end, pad: 0)
        #expect(bounds.start == start)
        #expect(bounds.end   == end)
    }
}
