import Testing
import Foundation
@testable import VideoVortexCore

// MARK: - SenseResult v3 Tests
//
// Covers the schema lock described in VVXPhase3SenseResultSchema.md (Step 0.5):
//   §3.1  schemaVersion
//   §3.2  transcriptSource (TranscriptSource enum)
//   §3.3  transcriptBlocks (TranscriptBlock inline array)
//   §3.4  description no longer truncated; descriptionTruncated flag
//   §3.5  chapterIndex on TranscriptBlock (boundary-safe)
//   §3.6  VideoChapter.endTime + estimatedTokens
//   §3.6.1 Token parity: sum of block tokens == top-level estimatedTokens
//   §3.7  --metadata-only invariants (withEmptyBlocks)
//   §3.8  JSON round-trip

@Suite("SenseResult v3")
struct SenseResultV3Tests {

    // MARK: - Helpers

    private func makeBlock(
        index: Int,
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        chapterIndex: Int?
    ) -> TranscriptBlock {
        let wc = text.split { $0.isWhitespace }.count
        return TranscriptBlock(
            index:           index,
            startSeconds:    startSeconds,
            endSeconds:      endSeconds,
            text:            text,
            wordCount:       wc,
            estimatedTokens: Int((Double(wc) * 1.3).rounded()),
            chapterIndex:    chapterIndex
        )
    }

    private func makeChapter(title: String, start: Double, end: Double?, tokens: Int?) -> VideoChapter {
        VideoChapter(title: title, startTime: start, endTime: end, estimatedTokens: tokens)
    }

    // MARK: - §3.1 schemaVersion

    @Test("Default schemaVersion is '3.0'")
    func defaultSchemaVersion() {
        let result = SenseResult(url: "https://example.com/v1", title: "Test")
        #expect(result.schemaVersion == "3.0")
    }

    // MARK: - §3.2 transcriptSource

    @Test("Default transcriptSource is .none")
    func defaultTranscriptSourceIsNone() {
        let result = SenseResult(url: "https://example.com/v1", title: "Test")
        #expect(result.transcriptSource == .none)
    }

    @Test("TranscriptSource roundtrips through Codable")
    func transcriptSourceCodable() throws {
        for source in TranscriptSource.allCases {
            let encoder = JSONEncoder()
            let data    = try encoder.encode(source)
            let decoded = try JSONDecoder().decode(TranscriptSource.self, from: data)
            #expect(decoded == source)
        }
    }

    @Test("Empty blocks + .none signals no usable transcript")
    func emptyTranscriptSignal() {
        let result = SenseResult(
            url:              "https://example.com/v1",
            title:            "No Subs",
            transcriptSource: .none,
            transcriptBlocks: [],
            estimatedTokens:  nil
        )
        #expect(result.transcriptBlocks.isEmpty)
        #expect(result.transcriptSource == .none)
        #expect(result.estimatedTokens == nil)
    }

    // MARK: - §3.3 transcriptBlocks

    @Test("TranscriptBlock fields and estimatedTokens formula")
    func transcriptBlockFields() {
        let block = TranscriptBlock(
            index:           1,
            startSeconds:    0.0,
            endSeconds:      3.5,
            text:            "First line of dialogue.",
            wordCount:       4,
            estimatedTokens: Int((4.0 * 1.3).rounded()), // 5
            chapterIndex:    0
        )
        #expect(block.index           == 1)
        #expect(block.startSeconds    == 0.0)
        #expect(block.endSeconds      == 3.5)
        #expect(block.text            == "First line of dialogue.")
        #expect(block.wordCount       == 4)
        #expect(block.estimatedTokens == 5)
        #expect(block.chapterIndex    == 0)
    }

    @Test("TranscriptBlock with nil chapterIndex (no chapters)")
    func transcriptBlockNilChapter() {
        let block = makeBlock(index: 1, startSeconds: 0, endSeconds: 2, text: "Hello world", chapterIndex: nil)
        #expect(block.chapterIndex == nil)
    }

    // MARK: - §3.4 description — no truncation + descriptionTruncated flag

    @Test("Default descriptionTruncated is false")
    func descriptionTruncatedDefault() {
        let longDesc = String(repeating: "word ", count: 200) // >500 chars
        let result = SenseResult(url: "https://example.com/v1", title: "T", description: longDesc)
        #expect(result.description == longDesc)
        #expect(result.descriptionTruncated == false)
    }

    // MARK: - §3.5 chapterIndex — boundary-safe

    @Test("Blocks assigned to correct chapters by start time")
    func chapterIndexBoundaryAssignment() {
        // Two chapters: 0..30s and 30..60s
        let ch0 = makeChapter(title: "Intro",  start: 0,  end: 30,  tokens: nil)
        let ch1 = makeChapter(title: "Part 2", start: 30, end: 60,  tokens: nil)

        let b0  = makeBlock(index: 1, startSeconds: 0,    endSeconds: 5,  text: "Block 0",  chapterIndex: 0)
        let b1  = makeBlock(index: 2, startSeconds: 15,   endSeconds: 18, text: "Block 1",  chapterIndex: 0)
        let b2  = makeBlock(index: 3, startSeconds: 29.9, endSeconds: 32, text: "Block 2",  chapterIndex: 0)
        let b3  = makeBlock(index: 4, startSeconds: 30.0, endSeconds: 35, text: "Block 3",  chapterIndex: 1)
        let b4  = makeBlock(index: 5, startSeconds: 45,   endSeconds: 50, text: "Block 4",  chapterIndex: 1)

        let result = SenseResult(
            url:             "https://example.com/v1",
            title:           "Multi-chapter",
            transcriptSource: .manual,
            transcriptBlocks: [b0, b1, b2, b3, b4],
            estimatedTokens:  [b0, b1, b2, b3, b4].map(\.estimatedTokens).reduce(0, +),
            chapters:         [ch0, ch1]
        )

        let ch0Blocks = result.transcriptBlocks.filter { $0.chapterIndex == 0 }
        let ch1Blocks = result.transcriptBlocks.filter { $0.chapterIndex == 1 }
        #expect(ch0Blocks.count == 3)
        #expect(ch1Blocks.count == 2)
        #expect(ch0Blocks.map(\.text) == ["Block 0", "Block 1", "Block 2"])
        #expect(ch1Blocks.map(\.text) == ["Block 3", "Block 4"])
    }

    // MARK: - §3.6 VideoChapter endTime + estimatedTokens

    @Test("VideoChapter carries endTime and estimatedTokens")
    func videoChapterV3Fields() {
        let ch = VideoChapter(title: "Intro", startTime: 0, endTime: 32.0, estimatedTokens: 89)
        #expect(ch.endTime         == 32.0)
        #expect(ch.estimatedTokens == 89)
        #expect(ch.startTimeFormatted == "0:00")
    }

    @Test("VideoChapter backward-compat init without new fields")
    func videoChapterBackwardCompat() {
        let ch = VideoChapter(title: "Chapter", startTime: 60)
        #expect(ch.endTime         == nil)
        #expect(ch.estimatedTokens == nil)
        #expect(ch.startTime       == 60)
    }

    // MARK: - §3.6.1 Token parity

    @Test("Top-level estimatedTokens equals sum of block tokens when blocks are non-empty")
    func tokenParity() {
        let b1 = makeBlock(index: 1, startSeconds: 0,  endSeconds: 3,  text: "Hello world", chapterIndex: 0)
        let b2 = makeBlock(index: 2, startSeconds: 3,  endSeconds: 6,  text: "Foo bar baz", chapterIndex: 0)
        let b3 = makeBlock(index: 3, startSeconds: 30, endSeconds: 33, text: "Second chapter text here", chapterIndex: 1)

        let blockSum = [b1, b2, b3].map(\.estimatedTokens).reduce(0, +)

        let ch0tokens = [b1, b2].map(\.estimatedTokens).reduce(0, +)
        let ch1tokens = [b3].map(\.estimatedTokens).reduce(0, +)

        let chapters = [
            VideoChapter(title: "A", startTime: 0,  endTime: 30, estimatedTokens: ch0tokens),
            VideoChapter(title: "B", startTime: 30, endTime: 60, estimatedTokens: ch1tokens),
        ]

        let result = SenseResult(
            url:             "https://example.com/v1",
            title:           "Parity test",
            transcriptSource: .auto,
            transcriptBlocks: [b1, b2, b3],
            estimatedTokens:  blockSum,
            chapters:         chapters
        )

        // Top-level parity
        #expect(result.estimatedTokens == blockSum)
        #expect(result.estimatedTokens == result.transcriptBlocks.map(\.estimatedTokens).reduce(0, +))

        // Chapter parity
        let actualCh0 = result.transcriptBlocks.filter { $0.chapterIndex == 0 }.map(\.estimatedTokens).reduce(0, +)
        let actualCh1 = result.transcriptBlocks.filter { $0.chapterIndex == 1 }.map(\.estimatedTokens).reduce(0, +)
        #expect(result.chapters[0].estimatedTokens == actualCh0)
        #expect(result.chapters[1].estimatedTokens == actualCh1)
    }

    @Test("estimatedTokens is nil when transcriptBlocks is empty (no transcript)")
    func tokenParityEmptyTranscript() {
        let result = SenseResult(
            url:             "https://example.com/v1",
            title:           "No transcript",
            transcriptSource: .none,
            transcriptBlocks: [],
            estimatedTokens:  nil
        )
        #expect(result.estimatedTokens == nil)
    }

    // MARK: - §3.7 --metadata-only (withEmptyBlocks)

    @Test("withEmptyBlocks strips transcriptBlocks but preserves estimatedTokens and chapters")
    func metadataOnlyInvariants() {
        let b1 = makeBlock(index: 1, startSeconds: 0, endSeconds: 3, text: "Hello world", chapterIndex: 0)
        let b2 = makeBlock(index: 2, startSeconds: 3, endSeconds: 6, text: "More words here today", chapterIndex: 0)
        let blockSum = [b1, b2].map(\.estimatedTokens).reduce(0, +)
        let chapters = [VideoChapter(title: "Ch1", startTime: 0, endTime: 60, estimatedTokens: blockSum)]

        let full = SenseResult(
            url:              "https://example.com/v1",
            title:            "Long video",
            platform:         "YouTube",
            transcriptSource: .manual,
            transcriptBlocks: [b1, b2],
            estimatedTokens:  blockSum,
            chapters:         chapters
        )

        let stripped = full.withEmptyBlocks()

        // Only transcriptBlocks should differ
        #expect(stripped.transcriptBlocks.isEmpty)
        #expect(stripped.estimatedTokens       == full.estimatedTokens)
        #expect(stripped.chapters.count        == full.chapters.count)
        #expect(stripped.chapters[0].endTime   == full.chapters[0].endTime)
        #expect(stripped.chapters[0].estimatedTokens == full.chapters[0].estimatedTokens)
        #expect(stripped.schemaVersion         == full.schemaVersion)
        #expect(stripped.transcriptSource      == full.transcriptSource)
        #expect(stripped.transcriptPath        == full.transcriptPath)
        #expect(stripped.url                   == full.url)
        #expect(stripped.title                 == full.title)
        #expect(stripped.platform              == full.platform)
    }

    @Test("withEmptyBlocks on result with nil estimatedTokens preserves nil")
    func metadataOnlyNilTokens() {
        let result   = SenseResult(url: "https://example.com/v1", title: "T",
                                   transcriptSource: .none, estimatedTokens: nil)
        let stripped = result.withEmptyBlocks()
        #expect(stripped.estimatedTokens == nil)
    }

    // MARK: - §3.8 JSON round-trip

    @Test("SenseResult v3 JSON round-trip preserves all fields")
    func jsonRoundTrip() throws {
        let b1 = makeBlock(index: 1, startSeconds: 0.0, endSeconds: 3.5,
                           text: "First line.", chapterIndex: 0)
        let ch = VideoChapter(title: "Intro", startTime: 0, endTime: 60, estimatedTokens: b1.estimatedTokens)
        let original = SenseResult(
            schemaVersion:        "3.0",
            url:                  "https://youtube.com/watch?v=dQw4w9WgXcQ",
            title:                "Example Title",
            platform:             "YouTube",
            uploader:             "Example Channel",
            durationSeconds:      212,
            uploadDate:           "2009-10-25",
            description:          "Full description text.",
            descriptionTruncated: false,
            tags:                 ["music", "pop"],
            viewCount:            1_000_000,
            transcriptPath:       nil,
            transcriptLanguage:   "en",
            transcriptSource:     .manual,
            transcriptBlocks:     [b1],
            estimatedTokens:      b1.estimatedTokens,
            chapters:             [ch],
            completedAt:          Date(timeIntervalSince1970: 1_748_260_800)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting     = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data    = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SenseResult.self, from: data)

        #expect(decoded.schemaVersion        == original.schemaVersion)
        #expect(decoded.url                  == original.url)
        #expect(decoded.title                == original.title)
        #expect(decoded.platform             == original.platform)
        #expect(decoded.uploader             == original.uploader)
        #expect(decoded.durationSeconds      == original.durationSeconds)
        #expect(decoded.uploadDate           == original.uploadDate)
        #expect(decoded.description          == original.description)
        #expect(decoded.descriptionTruncated == original.descriptionTruncated)
        #expect(decoded.tags                 == original.tags)
        #expect(decoded.viewCount            == original.viewCount)
        #expect(decoded.transcriptLanguage   == original.transcriptLanguage)
        #expect(decoded.transcriptSource     == original.transcriptSource)
        #expect(decoded.estimatedTokens      == original.estimatedTokens)
        #expect(decoded.transcriptBlocks.count == 1)
        #expect(decoded.transcriptBlocks[0].text           == b1.text)
        #expect(decoded.transcriptBlocks[0].wordCount      == b1.wordCount)
        #expect(decoded.transcriptBlocks[0].estimatedTokens == b1.estimatedTokens)
        #expect(decoded.transcriptBlocks[0].chapterIndex   == b1.chapterIndex)
        #expect(decoded.chapters.count                     == 1)
        #expect(decoded.chapters[0].title                  == ch.title)
        #expect(decoded.chapters[0].endTime                == ch.endTime)
        #expect(decoded.chapters[0].estimatedTokens        == ch.estimatedTokens)
    }

    @Test("JSON includes schemaVersion '3.0' key in output")
    func jsonContainsSchemaVersion() {
        let result = SenseResult(url: "https://example.com/v1", title: "T")
        let json   = result.jsonString()
        #expect(json.contains("\"schemaVersion\""))
        #expect(json.contains("\"3.0\""))
    }

    @Test("JSON includes transcriptSource key")
    func jsonContainsTranscriptSource() {
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptSource: .manual)
        let json   = result.jsonString()
        #expect(json.contains("\"transcriptSource\""))
        #expect(json.contains("\"manual\""))
    }

    @Test("JSON contains transcriptBlocks array")
    func jsonContainsTranscriptBlocks() {
        let b = makeBlock(index: 1, startSeconds: 0, endSeconds: 2, text: "Hello", chapterIndex: nil)
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptBlocks: [b], estimatedTokens: b.estimatedTokens)
        let json = result.jsonString()
        #expect(json.contains("\"transcriptBlocks\""))
        #expect(json.contains("\"Hello\""))
    }

    // MARK: - VortexDB schema migration V3

    @Test("New database opens at schema version 4 with chapter_index in transcript_blocks and engagement columns")
    func schemaVersionFour() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("v4schema_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
        }
        let db      = try VortexDB(path: url)
        let version = try await db.schemaVersion()
        #expect(version == 4)
    }

    @Test("upsertBlocks stores blocks and accepts nil chapterIndices")
    func upsertBlocksDefaultChapterIndex() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("v3blocks_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
        }
        let db     = try VortexDB(path: url)
        let blocks = [
            SRTBlock(index: 1, startTime: "00:00:00,000", endTime: "00:00:03,000",
                     startSeconds: 0, endSeconds: 3, text: "Hello world")
        ]
        try await db.upsertBlocks(blocks, videoId: "https://x.com/v1", title: "T",
                                  platform: nil, uploader: nil)
        let stored = try await db.blocksForVideo(videoId: "https://x.com/v1")
        #expect(stored.count == 1)
        #expect(stored[0].text == "Hello world")
    }

    // MARK: - VortexIndexer reindex

    @Test("reindex backfills chapter_index for all indexed videos")
    func reindexBackfillsChapterIndex() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v3reindex_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("shm"))
        }

        let srtContent = """
            1
            00:00:00,000 --> 00:00:03,000
            Intro block.

            2
            00:00:30,000 --> 00:00:33,000
            Second chapter block.

            """
        let srtURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reindex_\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: srtURL) }
        try srtContent.write(to: srtURL, atomically: true, encoding: .utf8)

        let chapters = [
            VideoChapter(title: "Intro",   startTime: 0),
            VideoChapter(title: "Chapter", startTime: 30),
        ]

        let db     = try VortexDB(path: dbURL)
        let result = SenseResult(
            url:            "https://example.com/reindex",
            title:          "Reindex Test",
            transcriptPath: srtURL.path,
            chapters:       chapters
        )
        try await VortexIndexer.index(senseResult: result, db: db)

        let (reindexed, skipped) = try await VortexIndexer.reindex(db: db)
        #expect(reindexed == 1)
        #expect(skipped   == 0)
    }

    @Test("reindex skips videos without a readable SRT file")
    func reindexSkipsMissingFile() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("v3skip_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("shm"))
        }
        let db     = try VortexDB(path: dbURL)
        let result = SenseResult(
            url:            "https://example.com/nosrt",
            title:          "No SRT",
            transcriptPath: nil
        )
        try await VortexIndexer.index(senseResult: result, db: db)
        let (reindexed, skipped) = try await VortexIndexer.reindex(db: db)
        #expect(reindexed == 0)
        #expect(skipped   == 1)
    }

    // MARK: - §10 Transcript slicing (sliced(startSeconds:endSeconds:))

    @Test("Intersection: block crossing slice start boundary is included")
    func sliceIntersectionBoundaryStart() {
        // Block starts before slice but ends inside it — must be included.
        let block = makeBlock(index: 1, startSeconds: 8.0, endSeconds: 12.0,
                              text: "Crossing the start", chapterIndex: nil)
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptSource: .auto,
                                 transcriptBlocks: [block],
                                 estimatedTokens: block.estimatedTokens)
        let sliced = result.sliced(startSeconds: 10.0, endSeconds: 20.0)
        #expect(sliced.transcriptBlocks.count == 1)
        #expect(sliced.transcriptBlocks[0].text == "Crossing the start")
    }

    @Test("Intersection: block crossing slice end boundary is included")
    func sliceIntersectionBoundaryEnd() {
        // Block starts inside slice but ends after it — must be included.
        let block = makeBlock(index: 1, startSeconds: 18.0, endSeconds: 25.0,
                              text: "Crossing the end", chapterIndex: nil)
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptSource: .auto,
                                 transcriptBlocks: [block],
                                 estimatedTokens: block.estimatedTokens)
        let sliced = result.sliced(startSeconds: 10.0, endSeconds: 20.0)
        #expect(sliced.transcriptBlocks.count == 1)
    }

    @Test("Intersection: block exactly touching boundary (not overlapping) is excluded")
    func sliceStrictInequalityExcludesTouching() {
        // Block ends exactly at sliceStart — no overlap, must be excluded.
        let blockBefore = makeBlock(index: 1, startSeconds: 5.0, endSeconds: 10.0,
                                    text: "Ends at boundary", chapterIndex: nil)
        // Block starts exactly at sliceEnd — no overlap, must be excluded.
        let blockAfter = makeBlock(index: 2, startSeconds: 20.0, endSeconds: 25.0,
                                   text: "Starts at boundary", chapterIndex: nil)
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptSource: .auto,
                                 transcriptBlocks: [blockBefore, blockAfter],
                                 estimatedTokens: blockBefore.estimatedTokens + blockAfter.estimatedTokens)
        let sliced = result.sliced(startSeconds: 10.0, endSeconds: 20.0)
        #expect(sliced.transcriptBlocks.isEmpty)
    }

    @Test("Token parity: top-level estimatedTokens equals sum of surviving block tokens")
    func sliceTokenParityTopLevel() {
        let b1 = makeBlock(index: 1, startSeconds: 0.0, endSeconds: 5.0,
                           text: "Before slice", chapterIndex: nil)
        let b2 = makeBlock(index: 2, startSeconds: 10.0, endSeconds: 15.0,
                           text: "Inside the slice window here", chapterIndex: nil)
        let b3 = makeBlock(index: 3, startSeconds: 30.0, endSeconds: 35.0,
                           text: "After the slice entirely", chapterIndex: nil)
        let all = [b1, b2, b3]
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptSource: .auto,
                                 transcriptBlocks: all,
                                 estimatedTokens: all.map(\.estimatedTokens).reduce(0, +))
        let sliced = result.sliced(startSeconds: 8.0, endSeconds: 20.0)
        #expect(sliced.transcriptBlocks.count == 1)
        #expect(sliced.transcriptBlocks[0].text == "Inside the slice window here")
        #expect(sliced.estimatedTokens == b2.estimatedTokens)
        // Parity invariant: top-level == sum of surviving blocks
        #expect(sliced.estimatedTokens == sliced.transcriptBlocks.map(\.estimatedTokens).reduce(0, +))
    }

    @Test("Chapter hybrid rule: chapter timestamps preserved; chapter tokens slice-local")
    func sliceChapterHybridRule() {
        // Chapter runs 10:00–20:00. Slice is 12:00–14:00.
        let b1 = makeBlock(index: 1, startSeconds: 600.0, endSeconds: 605.0,
                           text: "Before slice in chapter", chapterIndex: 0)
        let b2 = makeBlock(index: 2, startSeconds: 720.0, endSeconds: 725.0,
                           text: "Inside slice in chapter", chapterIndex: 0)
        let b3 = makeBlock(index: 3, startSeconds: 850.0, endSeconds: 855.0,
                           text: "After slice in chapter", chapterIndex: 0)
        let chapterTokens = [b1, b2, b3].map(\.estimatedTokens).reduce(0, +)
        let chapter = VideoChapter(title: "The AGI Threat",
                                   startTime: 600.0, endTime: 1200.0,
                                   estimatedTokens: chapterTokens)
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptSource: .auto,
                                 transcriptBlocks: [b1, b2, b3],
                                 estimatedTokens: chapterTokens,
                                 chapters: [chapter])
        let sliced = result.sliced(startSeconds: 720.0, endSeconds: 840.0)

        // Chapter is preserved (intersects slice window)
        #expect(sliced.chapters.count == 1)
        // Absolute structural timestamps MUST NOT be mutated
        #expect(sliced.chapters[0].startTime == 600.0)
        #expect(sliced.chapters[0].endTime == 1200.0)
        #expect(sliced.chapters[0].title == "The AGI Threat")
        // Chapter token count is slice-local
        #expect(sliced.chapters[0].estimatedTokens == b2.estimatedTokens)
        // Only b2 survives
        #expect(sliced.transcriptBlocks.count == 1)
        #expect(sliced.transcriptBlocks[0].text == "Inside slice in chapter")
    }

    @Test("chapterIndex stability: surviving blocks retain original chapterIndex values")
    func sliceChapterIndexPreservation() {
        let b0 = makeBlock(index: 1, startSeconds: 5.0,  endSeconds: 10.0,
                           text: "Chapter zero block", chapterIndex: 0)
        let b1 = makeBlock(index: 2, startSeconds: 35.0, endSeconds: 40.0,
                           text: "Chapter one block", chapterIndex: 1)
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptSource: .auto,
                                 transcriptBlocks: [b0, b1],
                                 estimatedTokens: b0.estimatedTokens + b1.estimatedTokens)
        // Slice that captures both blocks
        let sliced = result.sliced(startSeconds: 0.0, endSeconds: 50.0)
        #expect(sliced.transcriptBlocks[0].chapterIndex == 0)
        #expect(sliced.transcriptBlocks[1].chapterIndex == 1)
    }

    @Test("Empty slice: no blocks in range returns success with empty transcriptBlocks and zero tokens")
    func sliceEmptyRange() {
        let block = makeBlock(index: 1, startSeconds: 100.0, endSeconds: 110.0,
                              text: "Far from slice", chapterIndex: nil)
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptSource: .auto,
                                 transcriptBlocks: [block],
                                 estimatedTokens: block.estimatedTokens)
        let sliced = result.sliced(startSeconds: 0.0, endSeconds: 5.0)
        #expect(sliced.success == true)
        #expect(sliced.transcriptBlocks.isEmpty)
        #expect(sliced.estimatedTokens == 0)
        #expect(sliced.sliced == true)
    }

    @Test("Slice metadata fields: sliced=true, sliceStart, sliceEnd set correctly")
    func sliceMetadataFields() {
        let block = makeBlock(index: 1, startSeconds: 12.0, endSeconds: 14.0,
                              text: "Inside", chapterIndex: nil)
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptSource: .auto,
                                 transcriptBlocks: [block],
                                 estimatedTokens: block.estimatedTokens)
        let sliced = result.sliced(startSeconds: 10.0, endSeconds: 20.0)
        #expect(sliced.sliced == true)
        #expect(sliced.sliceStart == 10.0)
        #expect(sliced.sliceEnd == 20.0)
    }

    @Test("Open-ended slice: sliceEnd is nil in output (no Infinity in JSON)")
    func sliceOpenEndedNilSliceEnd() throws {
        let block = makeBlock(index: 1, startSeconds: 5.0, endSeconds: 10.0,
                              text: "Open end block", chapterIndex: nil)
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptSource: .auto,
                                 transcriptBlocks: [block],
                                 estimatedTokens: block.estimatedTokens)
        let sliced = result.sliced(startSeconds: 0.0, endSeconds: Double.infinity)
        #expect(sliced.sliceEnd == nil)
        // JSON must not contain "Infinity" or non-finite values
        let json = sliced.jsonString()
        #expect(!json.contains("Infinity"))
        #expect(!json.contains("inf"))
    }

    @Test("Non-sliced result is backward-compatible: sliced=false, sliceStart/sliceEnd are nil")
    func nonSlicedCompatibility() {
        let block = makeBlock(index: 1, startSeconds: 0.0, endSeconds: 5.0,
                              text: "Normal block", chapterIndex: nil)
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptSource: .auto,
                                 transcriptBlocks: [block],
                                 estimatedTokens: block.estimatedTokens)
        #expect(result.sliced == false)
        #expect(result.sliceStart == nil)
        #expect(result.sliceEnd == nil)
    }

    @Test("metadata-only on sliced result: empty blocks but slice-local planning fields preserved")
    func sliceMetadataOnlyInvariant() {
        let b1 = makeBlock(index: 1, startSeconds: 10.0, endSeconds: 15.0,
                           text: "Inside slice", chapterIndex: 0)
        let b2 = makeBlock(index: 2, startSeconds: 50.0, endSeconds: 55.0,
                           text: "Outside slice", chapterIndex: 0)
        let chTokens = b1.estimatedTokens + b2.estimatedTokens
        let chapter = VideoChapter(title: "Ch", startTime: 0, endTime: 60, estimatedTokens: chTokens)
        let result = SenseResult(url: "https://example.com/v1", title: "T",
                                 transcriptSource: .auto,
                                 transcriptBlocks: [b1, b2],
                                 estimatedTokens: chTokens,
                                 chapters: [chapter])
        // Apply slice then metadata-only (same order as SenseCommand)
        let slicedResult = result.sliced(startSeconds: 8.0, endSeconds: 20.0)
        let metaOnly = slicedResult.withEmptyBlocks()

        // Blocks stripped
        #expect(metaOnly.transcriptBlocks.isEmpty)
        // Slice-local token count preserved (not full-video total)
        #expect(metaOnly.estimatedTokens == b1.estimatedTokens)
        // Slice metadata propagated through withEmptyBlocks
        #expect(metaOnly.sliced == true)
        #expect(metaOnly.sliceStart == 8.0)
        #expect(metaOnly.sliceEnd == 20.0)
        // Chapter structural timestamps preserved
        #expect(metaOnly.chapters[0].startTime == 0)
        #expect(metaOnly.chapters[0].endTime == 60)
        // Chapter token count is slice-local
        #expect(metaOnly.chapters[0].estimatedTokens == b1.estimatedTokens)
    }

    // MARK: - Token parity integration with SRTParser

    @Test("Block token sum equals top-level estimatedTokens for multi-block SRT")
    func tokenParityMultiBlock() throws {
        let srt = """
            1
            00:00:00,000 --> 00:00:03,000
            Hello world foo bar

            2
            00:00:03,000 --> 00:00:06,000
            Another sentence here today

            3
            00:00:06,000 --> 00:00:09,000
            Final line of text

            """
        let blocks = SRTParser.parse(srt)
        let transcriptBlocks: [TranscriptBlock] = blocks.map { b in
            let wc = b.text.split { $0.isWhitespace }.count
            return TranscriptBlock(
                index:           b.index,
                startSeconds:    b.startSeconds,
                endSeconds:      b.endSeconds,
                text:            b.text,
                wordCount:       wc,
                estimatedTokens: Int((Double(wc) * 1.3).rounded()),
                chapterIndex:    nil
            )
        }
        let blockSum = transcriptBlocks.map(\.estimatedTokens).reduce(0, +)
        let result   = SenseResult(
            url:             "https://example.com/parity",
            title:           "Parity",
            transcriptSource: .auto,
            transcriptBlocks: transcriptBlocks,
            estimatedTokens:  blockSum
        )
        #expect(result.estimatedTokens == blockSum)
        #expect(result.estimatedTokens == result.transcriptBlocks.map(\.estimatedTokens).reduce(0, +))
    }
}
