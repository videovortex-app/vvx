import XCTest
@testable import VideoVortexCore

// MARK: - ProximityAnalyzerTests

final class ProximityAnalyzerTests: XCTestCase {

    // MARK: - minimumWindow — basic two-term case

    func testMinimumWindow_twoTermsTight() {
        let termHits: [String: [ProximityHit]] = [
            "AGI":      [hit(term: "AGI",      start: 10.0, end: 13.0, text: "AGI talk")],
            "security": [hit(term: "security", start: 18.0, end: 21.0, text: "security risk")]
        ]
        let result = ProximityAnalyzer.minimumWindow(
            termHits: termHits, withinSeconds: 30, blocks: []
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.startSeconds, 10.0)
        XCTAssertEqual(result?.proximitySpanSeconds ?? -1, 8.0, accuracy: 0.001)
        XCTAssertEqual(result?.termHits.count, 2)
    }

    // MARK: - minimumWindow — picks tightest of multiple candidates

    func testMinimumWindow_picksTightestWindow() {
        // Two valid windows: (10s→30s, span=20) and (60s→65s, span=5). Tightest should win.
        let termHits: [String: [ProximityHit]] = [
            "AGI": [
                hit(term: "AGI", start: 10.0, end: 12.0, text: "A"),
                hit(term: "AGI", start: 60.0, end: 62.0, text: "C")
            ],
            "security": [
                hit(term: "security", start: 30.0, end: 32.0, text: "B"),
                hit(term: "security", start: 65.0, end: 67.0, text: "D")
            ]
        ]
        let result = ProximityAnalyzer.minimumWindow(
            termHits: termHits, withinSeconds: 60, blocks: []
        )
        XCTAssertNotNil(result)
        // Window 60→65: span = 5. Window 10→30: span = 20. Tightest wins.
        XCTAssertEqual(result?.proximitySpanSeconds ?? -1, 5.0, accuracy: 0.001)
        XCTAssertEqual(result?.startSeconds ?? -1, 60.0, accuracy: 0.001)
    }

    // MARK: - minimumWindow — window exceeds threshold → nil

    func testMinimumWindow_windowExceedsThreshold() {
        let termHits: [String: [ProximityHit]] = [
            "AGI":      [hit(term: "AGI",      start: 0.0,  end: 3.0,  text: "AGI")],
            "security": [hit(term: "security", start: 40.0, end: 43.0, text: "security")]
        ]
        // Only window has span = 40 s; threshold = 30 → nil
        let result = ProximityAnalyzer.minimumWindow(
            termHits: termHits, withinSeconds: 30, blocks: []
        )
        XCTAssertNil(result)
    }

    // MARK: - minimumWindow — single term → nil

    func testMinimumWindow_singleTerm() {
        let termHits: [String: [ProximityHit]] = [
            "AGI": [hit(term: "AGI", start: 0.0, end: 3.0, text: "AGI")]
        ]
        let result = ProximityAnalyzer.minimumWindow(
            termHits: termHits, withinSeconds: 30, blocks: []
        )
        XCTAssertNil(result)
    }

    // MARK: - minimumWindow — empty hit list for one term → nil

    func testMinimumWindow_emptyHitlistForOneTerm() {
        let termHits: [String: [ProximityHit]] = [
            "AGI":      [hit(term: "AGI", start: 10.0, end: 13.0, text: "AGI")],
            "security": []   // no hits
        ]
        let result = ProximityAnalyzer.minimumWindow(
            termHits: termHits, withinSeconds: 30, blocks: []
        )
        XCTAssertNil(result)
    }

    // MARK: - minimumWindow — cross-block collision (FTS5 NEAR would miss this)

    func testMinimumWindow_crossBlockCollision() {
        // "AGI" ends a block at 5:00.8; "security" starts next block at 5:01.2 — gap 0.4 s.
        let termHits: [String: [ProximityHit]] = [
            "AGI":      [hit(term: "AGI",      start: 300.8, end: 303.8, text: "AGI dev")],
            "security": [hit(term: "security", start: 301.2, end: 304.2, text: "security")]
        ]
        let result = ProximityAnalyzer.minimumWindow(
            termHits: termHits, withinSeconds: 10, blocks: []
        )
        XCTAssertNotNil(result, "Cross-block collision within threshold must be found")
        XCTAssertEqual(result?.proximitySpanSeconds ?? -1, 0.4, accuracy: 0.01)
    }

    // MARK: - minimumWindow — three terms

    func testMinimumWindow_threeTerms() {
        let termHits: [String: [ProximityHit]] = [
            "AGI":       [hit(term: "AGI",       start: 10.0, end: 12.0, text: "AGI")],
            "security":  [hit(term: "security",  start: 15.0, end: 17.0, text: "security")],
            "timeline":  [hit(term: "timeline",  start: 20.0, end: 22.0, text: "timeline")]
        ]
        let result = ProximityAnalyzer.minimumWindow(
            termHits: termHits, withinSeconds: 30, blocks: []
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.proximitySpanSeconds ?? -1, 10.0, accuracy: 0.001)
        XCTAssertEqual(result?.termHits.count, 3)
    }

    // MARK: - minimumWindow — withinSeconds <= 0 → nil

    func testMinimumWindow_zeroWithin() {
        let termHits: [String: [ProximityHit]] = [
            "AGI":      [hit(term: "AGI",      start: 0.0,  end: 3.0, text: "AGI")],
            "security": [hit(term: "security", start: 0.5, end: 3.5, text: "security")]
        ]
        XCTAssertNil(ProximityAnalyzer.minimumWindow(
            termHits: termHits, withinSeconds: 0, blocks: []
        ))
        XCTAssertNil(ProximityAnalyzer.minimumWindow(
            termHits: termHits, withinSeconds: -5, blocks: []
        ))
    }

    // MARK: - termHits: rightmost occurrence per term

    func testMinimumWindow_termHitsUseRightmostOccurrence() {
        // "AGI" has two hits at 10 and 15. "security" hits at 18.
        // Tightest window is [15, 18] (span=3). The rep hit for "AGI" should be the one at 15.
        let termHits: [String: [ProximityHit]] = [
            "AGI": [
                hit(term: "AGI", start: 10.0, end: 12.0, text: "AGI early"),
                hit(term: "AGI", start: 15.0, end: 17.0, text: "AGI later")
            ],
            "security": [hit(term: "security", start: 18.0, end: 20.0, text: "security")]
        ]
        let result = ProximityAnalyzer.minimumWindow(
            termHits: termHits, withinSeconds: 30, blocks: []
        )
        XCTAssertNotNil(result)
        let agiHit = result?.termHits.first(where: { $0.term == "AGI" })
        XCTAssertEqual(agiHit?.startSeconds ?? -1, 15.0,
                       "Rightmost AGI hit (15 s) should be the rep in the tightest window")
    }

    // MARK: - transcriptExcerpt

    func testMinimumWindow_transcriptExcerptNonEmpty() {
        let blocks = [
            block(start: 9.0,  end: 12.0, text: "Block before"),
            block(start: 10.0, end: 13.0, text: "AGI talk here"),
            block(start: 15.0, end: 18.0, text: "security risk now"),
            block(start: 25.0, end: 28.0, text: "Block after")
        ]
        let termHits: [String: [ProximityHit]] = [
            "AGI":      [hit(term: "AGI",      start: 10.0, end: 13.0, text: "AGI talk here")],
            "security": [hit(term: "security", start: 15.0, end: 18.0, text: "security risk now")]
        ]
        let result = ProximityAnalyzer.minimumWindow(
            termHits: termHits, withinSeconds: 30, blocks: blocks
        )
        XCTAssertNotNil(result?.transcriptExcerpt)
        XCTAssertFalse(result?.transcriptExcerpt.isEmpty ?? true)
        XCTAssertTrue(result?.transcriptExcerpt.contains("AGI") ?? false)
    }

    func testMinimumWindow_transcriptExcerptTruncatedAt1000() {
        // Build blocks with text > 1000 chars within the window.
        let longText = Array(repeating: "word", count: 300).joined(separator: " ")  // ~1200 chars
        let blocks = [
            block(start: 10.0, end: 15.0, text: longText),
            block(start: 15.0, end: 20.0, text: longText)
        ]
        let termHits: [String: [ProximityHit]] = [
            "AGI":      [hit(term: "AGI",      start: 10.0, end: 15.0, text: "AGI")],
            "security": [hit(term: "security", start: 15.0, end: 20.0, text: "security")]
        ]
        let result = ProximityAnalyzer.minimumWindow(
            termHits: termHits, withinSeconds: 30, blocks: blocks
        )
        XCTAssertLessThanOrEqual(result?.transcriptExcerpt.count ?? Int.max, 1000)
    }

    // MARK: - excerptFromBlocks — ±0.5 s buffer

    func testExcerptFromBlocks_includesBufferBlocks() {
        let blocks = [
            block(start: 9.6,  end: 12.0, text: "Buffer before"),   // within -0.5 of from=10
            block(start: 10.0, end: 13.0, text: "Core block"),
            block(start: 20.4, end: 23.0, text: "Buffer after"),    // within +0.5 of to=20
            block(start: 25.0, end: 28.0, text: "Too far")
        ]
        let excerpt = ProximityAnalyzer.excerptFromBlocks(blocks, from: 10.0, to: 20.0, maxChars: 5000)
        XCTAssertTrue(excerpt.contains("Buffer before"))
        XCTAssertTrue(excerpt.contains("Core block"))
        XCTAssertTrue(excerpt.contains("Buffer after"))
        XCTAssertFalse(excerpt.contains("Too far"))
    }

    // MARK: - collectRepHits

    func testCollectRepHits_rightmostPerTerm() {
        let slice: ArraySlice<(term: String, hit: ProximityHit)> = [
            (term: "AGI",      hit: hit(term: "AGI",      start: 5.0,  end: 7.0,  text: "first")),
            (term: "security", hit: hit(term: "security", start: 8.0,  end: 10.0, text: "sec")),
            (term: "AGI",      hit: hit(term: "AGI",      start: 12.0, end: 14.0, text: "last"))
        ][0...]
        let reps = ProximityAnalyzer.collectRepHits(slice, Set(["AGI", "security"]))
        let agiRep = reps.first(where: { $0.term == "AGI" })
        XCTAssertEqual(agiRep?.startSeconds ?? -1, 12.0, "Rightmost AGI hit must be selected")
        XCTAssertEqual(agiRep?.text, "last")
    }

    // MARK: - Helpers

    private func hit(term: String, start: Double, end: Double, text: String) -> ProximityHit {
        ProximityHit(term: term, startSeconds: start, endSeconds: end, text: text)
    }

    private func block(start: Double, end: Double, text: String) -> StoredBlock {
        StoredBlock(
            startTime:    timestampString(start),
            endTime:      timestampString(end),
            startSeconds: start,
            endSeconds:   end,
            text:         text
        )
    }

    private func timestampString(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d,000", h, m, s)
    }
}
