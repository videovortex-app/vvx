import Testing
import Foundation
@testable import VideoVortexCore

// MARK: - SRTSearcher Tests
// Covers every case listed in §13 of VVXPhase3Roadmap.md.
// All search tests are async because VortexDB is an actor.

@Suite("SRTSearcher")
struct SRTSearcherTests {

    // MARK: - DB helpers

    private func makeDB() async throws -> (VortexDB, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("searcher_test_\(UUID().uuidString).db")
        let db = try VortexDB(path: url)
        return (db, url)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Insert a minimal video record + the given blocks into `db`.
    private func seedVideo(
        db: VortexDB,
        videoId: String,
        title: String,
        platform: String = "YouTube",
        uploader: String = "TestChannel",
        uploadDate: String = "2026-01-01",
        videoPath: String? = nil,
        transcriptPath: String? = nil,
        blocks: [SRTBlock]
    ) async throws {
        try await db.upsertVideo(VideoRecord(
            id:             videoId,
            title:          title,
            platform:       platform,
            uploader:       uploader,
            uploadDate:     uploadDate,
            transcriptPath: transcriptPath,
            videoPath:      videoPath,
            sensedAt:       "2026-01-01T00:00:00Z"
        ))
        try await db.upsertBlocks(
            blocks,
            videoId:  videoId,
            title:    title,
            platform: platform,
            uploader: uploader
        )
    }

    // MARK: - testNoResults

    @Test("Query with no matches returns empty results array")
    func testNoResults() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        try await seedVideo(
            db: db,
            videoId: "https://youtube.com/watch?v=nr1",
            title: "Cooking Show",
            blocks: [
                SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                         startSeconds: 1.0, endSeconds: 4.0, text: "Today we make pasta."),
            ]
        )

        let output = try await SRTSearcher.search(query: "xylophone quantum zigzag", db: db)

        #expect(output.success == true)
        #expect(output.totalMatches == 0)
        #expect(output.results.isEmpty)
        #expect(output.query == "xylophone quantum zigzag")
    }

    // MARK: - testSingleMatch

    @Test("Exact phrase returns exactly one hit")
    func testSingleMatch() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        try await seedVideo(
            db: db,
            videoId: "https://youtube.com/watch?v=sm1",
            title: "AI Podcast",
            blocks: [
                SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                         startSeconds: 1.0, endSeconds: 4.0,
                         text: "Artificial general intelligence will change everything."),
                SRTBlock(index: 2, startTime: "00:00:05,000", endTime: "00:00:08,000",
                         startSeconds: 5.0, endSeconds: 8.0,
                         text: "The weather is quite nice today."),
            ]
        )

        let output = try await SRTSearcher.search(query: "\"artificial general intelligence\"", db: db)

        #expect(output.totalMatches == 1)
        #expect(output.results[0].snippet.lowercased().contains("artificial general intelligence"))
        #expect(output.results[0].rank == 1)
        #expect(output.results[0].videoTitle == "AI Podcast")
    }

    // MARK: - testMultipleMatchesSameFile

    @Test("Three hits in the same video are all returned")
    func testMultipleMatchesSameFile() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        try await seedVideo(
            db: db,
            videoId: "https://youtube.com/watch?v=multi1",
            title: "Space Talk",
            blocks: [
                SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                         startSeconds: 1.0, endSeconds: 4.0, text: "Mars colonization is the goal."),
                SRTBlock(index: 2, startTime: "00:00:05,000", endTime: "00:00:08,000",
                         startSeconds: 5.0, endSeconds: 8.0, text: "Nobody mentioned mars here."),
                SRTBlock(index: 3, startTime: "00:00:09,000", endTime: "00:00:12,000",
                         startSeconds: 9.0, endSeconds: 12.0, text: "The latest mars rover results."),
                SRTBlock(index: 4, startTime: "00:00:13,000", endTime: "00:00:16,000",
                         startSeconds: 13.0, endSeconds: 16.0, text: "Back to cooking now."),
                SRTBlock(index: 5, startTime: "00:00:17,000", endTime: "00:00:20,000",
                         startSeconds: 17.0, endSeconds: 20.0, text: "Mars exploration is critical."),
            ]
        )

        let output = try await SRTSearcher.search(query: "mars", db: db)

        // Blocks 1, 2 (via stemming "mentioned mars"), 3, and 5 all mention Mars.
        // We just assert that we get at least 3 and all reference the same video.
        #expect(output.totalMatches >= 3)
        for result in output.results {
            #expect(result.videoTitle == "Space Talk")
        }
    }

    // MARK: - testMatchesAcrossFiles

    @Test("Hits spanning multiple videos are all returned with correct attribution")
    func testMatchesAcrossFiles() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let videos = [
            ("https://youtube.com/watch?v=af1", "Podcast A"),
            ("https://youtube.com/watch?v=af2", "Podcast B"),
            ("https://youtube.com/watch?v=af3", "Podcast C"),
        ]
        for (videoId, title) in videos {
            try await seedVideo(
                db: db,
                videoId: videoId,
                title: title,
                blocks: [
                    SRTBlock(index: 1, startTime: "00:01:00,000", endTime: "00:01:03,000",
                             startSeconds: 60.0, endSeconds: 63.0,
                             text: "We discuss artificial intelligence at length."),
                    SRTBlock(index: 2, startTime: "00:01:04,000", endTime: "00:01:07,000",
                             startSeconds: 64.0, endSeconds: 67.0,
                             text: "The future is unwritten."),
                ]
            )
        }

        let output = try await SRTSearcher.search(query: "artificial intelligence", db: db)

        #expect(output.totalMatches == 3)
        let titles = Set(output.results.map(\.videoTitle))
        #expect(titles.count == 3)
        #expect(titles.contains("Podcast A"))
        #expect(titles.contains("Podcast B"))
        #expect(titles.contains("Podcast C"))
    }

    // MARK: - testContextWindow

    @Test("Context window includes exactly 2 blocks before and 2 after the hit")
    func testContextWindow() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        // 7 blocks — the hit is block 4 (0-indexed: 3), so we expect blocks 2+3 before
        // and blocks 5+6 after.
        let blocks = [
            SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                     startSeconds: 1.0, endSeconds: 4.0, text: "Block one text."),
            SRTBlock(index: 2, startTime: "00:00:05,000", endTime: "00:00:08,000",
                     startSeconds: 5.0, endSeconds: 8.0, text: "Block two text."),
            SRTBlock(index: 3, startTime: "00:00:09,000", endTime: "00:00:12,000",
                     startSeconds: 9.0, endSeconds: 12.0, text: "Block three text."),
            SRTBlock(index: 4, startTime: "00:00:13,000", endTime: "00:00:16,000",
                     startSeconds: 13.0, endSeconds: 16.0,
                     text: "The matched unique phrase is here."),
            SRTBlock(index: 5, startTime: "00:00:17,000", endTime: "00:00:20,000",
                     startSeconds: 17.0, endSeconds: 20.0, text: "Block five text."),
            SRTBlock(index: 6, startTime: "00:00:21,000", endTime: "00:00:24,000",
                     startSeconds: 21.0, endSeconds: 24.0, text: "Block six text."),
            SRTBlock(index: 7, startTime: "00:00:25,000", endTime: "00:00:28,000",
                     startSeconds: 25.0, endSeconds: 28.0, text: "Block seven text."),
        ]

        try await seedVideo(
            db: db,
            videoId: "https://youtube.com/watch?v=ctx1",
            title: "Context Test",
            blocks: blocks
        )

        let output = try await SRTSearcher.search(query: "\"unique phrase\"", db: db)

        #expect(output.totalMatches == 1)
        let result = output.results[0]

        // contextBefore should contain blocks 2 and 3 (the two immediately preceding).
        #expect(result.contextBefore.contains("Block two text"))
        #expect(result.contextBefore.contains("Block three text"))
        // Block one is further away than 2 back — it must NOT be in contextBefore.
        #expect(!result.contextBefore.contains("Block one text"))

        // contextAfter should contain blocks 5 and 6.
        #expect(result.contextAfter.contains("Block five text"))
        #expect(result.contextAfter.contains("Block six text"))
        // Block seven is further away — it must NOT be in contextAfter.
        #expect(!result.contextAfter.contains("Block seven text"))
    }

    @Test("Context window at start-of-video returns empty contextBefore")
    func testContextWindowAtStart() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let blocks = [
            SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                     startSeconds: 1.0, endSeconds: 4.0,
                     text: "This is the very first block with unique content here."),
            SRTBlock(index: 2, startTime: "00:00:05,000", endTime: "00:00:08,000",
                     startSeconds: 5.0, endSeconds: 8.0, text: "Second block."),
        ]
        try await seedVideo(
            db: db, videoId: "https://youtube.com/watch?v=ctxstart",
            title: "Start Test", blocks: blocks
        )

        let output = try await SRTSearcher.search(query: "\"very first block\"", db: db)

        #expect(output.totalMatches == 1)
        #expect(output.results[0].contextBefore == "")
        #expect(output.results[0].contextAfter.contains("Second block"))
    }

    @Test("Context window at end-of-video returns empty contextAfter")
    func testContextWindowAtEnd() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let blocks = [
            SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                     startSeconds: 1.0, endSeconds: 4.0, text: "First block."),
            SRTBlock(index: 2, startTime: "00:00:05,000", endTime: "00:00:08,000",
                     startSeconds: 5.0, endSeconds: 8.0,
                     text: "This is the absolute last block with unique finale."),
        ]
        try await seedVideo(
            db: db, videoId: "https://youtube.com/watch?v=ctxend",
            title: "End Test", blocks: blocks
        )

        let output = try await SRTSearcher.search(query: "\"unique finale\"", db: db)

        #expect(output.totalMatches == 1)
        #expect(output.results[0].contextAfter == "")
        #expect(output.results[0].contextBefore.contains("First block"))
    }

    // MARK: - testRankOrdering

    @Test("Exact phrase hit is ranked above partial match")
    func testRankOrdering() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        // Two videos: one has the exact phrase "machine learning safety",
        // the other has the words scattered.
        try await seedVideo(
            db: db,
            videoId: "https://youtube.com/watch?v=rank_exact",
            title: "Exact Match Video",
            blocks: [
                SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                         startSeconds: 1.0, endSeconds: 4.0,
                         text: "machine learning safety is the key concern."),
            ]
        )
        try await seedVideo(
            db: db,
            videoId: "https://youtube.com/watch?v=rank_partial",
            title: "Partial Match Video",
            blocks: [
                SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                         startSeconds: 1.0, endSeconds: 4.0,
                         text: "learning is a machine process that covers many areas of safety."),
            ]
        )

        let output = try await SRTSearcher.search(query: "\"machine learning safety\"", db: db)

        // The exact phrase match must appear first.
        #expect(output.results.count >= 1)
        #expect(output.results[0].videoTitle == "Exact Match Video")
        // bm25 score is more negative for better matches.
        if output.results.count >= 2 {
            #expect(output.results[0].relevanceScore <= output.results[1].relevanceScore)
        }
    }

    // MARK: - testVideoPathResolved

    @Test("Result videoPath and transcriptPath are populated from the videos table")
    func testVideoPathResolved() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let expectedVideoPath      = "/Users/mike/.vvx/archive/YouTube/Test/video.mp4"
        let expectedTranscriptPath = "/Users/mike/.vvx/transcripts/video.en.srt"

        try await seedVideo(
            db: db,
            videoId:        "https://youtube.com/watch?v=paths1",
            title:          "Path Test",
            videoPath:      expectedVideoPath,
            transcriptPath: expectedTranscriptPath,
            blocks: [
                SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                         startSeconds: 1.0, endSeconds: 4.0,
                         text: "Exploring the frontier of generative models today."),
            ]
        )

        let output = try await SRTSearcher.search(query: "generative models", db: db)

        #expect(output.totalMatches == 1)
        #expect(output.results[0].videoPath      == expectedVideoPath)
        #expect(output.results[0].transcriptPath == expectedTranscriptPath)
    }

    // MARK: - testTimestampFormatting (pure function)

    @Test("formatTimestamp strips milliseconds from SRT timestamp")
    func testTimestampFormatting() {
        #expect(SRTSearcher.formatTimestamp("00:14:32,000") == "00:14:32")
        #expect(SRTSearcher.formatTimestamp("01:02:03,500") == "01:02:03")
        #expect(SRTSearcher.formatTimestamp("00:14:32.040") == "00:14:32")
        // No separator — returned unchanged.
        #expect(SRTSearcher.formatTimestamp("00:14:32")     == "00:14:32")
    }

    // MARK: - testContextWindowPureFunction (unit test the static helper directly)

    @Test("contextWindow helper returns correct 2-before / 2-after slices with timestamps")
    func testContextWindowPureFunction() {
        let blocks: [StoredBlock] = [
            StoredBlock(startTime: "00:00:01,000", endTime: "00:00:04,000", startSeconds: 1.0, endSeconds: 4.0, text: "A"),
            StoredBlock(startTime: "00:00:05,000", endTime: "00:00:08,000", startSeconds: 5.0, endSeconds: 8.0, text: "B"),
            StoredBlock(startTime: "00:00:09,000", endTime: "00:00:12,000", startSeconds: 9.0, endSeconds: 12.0, text: "C"),
            StoredBlock(startTime: "00:00:13,000", endTime: "00:00:16,000", startSeconds: 13.0, endSeconds: 16.0, text: "D"),
            StoredBlock(startTime: "00:00:17,000", endTime: "00:00:20,000", startSeconds: 17.0, endSeconds: 20.0, text: "E"),
        ]

        // Hit is block "C" (index 2).
        let (before, after, beforeBlocks, afterBlocks) = SRTSearcher.contextWindow(for: 9.0, blocks: blocks)
        #expect(before == "A B")
        #expect(after  == "D E")
        #expect(beforeBlocks.map(\.text) == ["A", "B"])
        #expect(afterBlocks.map(\.text)  == ["D", "E"])
        // Timestamps must be stripped of milliseconds.
        #expect(beforeBlocks[0].timestamp == "00:00:01")
        #expect(beforeBlocks[1].timestamp == "00:00:05")
        #expect(afterBlocks[0].timestamp  == "00:00:13")
        #expect(afterBlocks[1].timestamp  == "00:00:17")

        // Hit is block "A" (index 0) — no blocks before.
        let (before2, after2, beforeBlocks2, afterBlocks2) = SRTSearcher.contextWindow(for: 1.0, blocks: blocks)
        #expect(before2 == "")
        #expect(after2  == "B C")
        #expect(beforeBlocks2.isEmpty)
        #expect(afterBlocks2.map(\.text) == ["B", "C"])

        // Hit is block "E" (index 4) — no blocks after.
        let (before3, after3, beforeBlocks3, afterBlocks3) = SRTSearcher.contextWindow(for: 17.0, blocks: blocks)
        #expect(before3 == "C D")
        #expect(after3  == "")
        #expect(beforeBlocks3.map(\.text) == ["C", "D"])
        #expect(afterBlocks3.isEmpty)

        // Unknown startSeconds — all empty.
        let (before4, after4, beforeBlocks4, afterBlocks4) = SRTSearcher.contextWindow(for: 999.0, blocks: blocks)
        #expect(before4 == "")
        #expect(after4  == "")
        #expect(beforeBlocks4.isEmpty)
        #expect(afterBlocks4.isEmpty)
    }

    // MARK: - testResolveChapter

    @Test("resolveChapter returns the chapter the hit falls within")
    func testResolveChapter() {
        let chapters = [
            VideoChapter(title: "Introduction", startTime: 0.0),
            VideoChapter(title: "The Argument",  startTime: 600.0),   // 10:00
            VideoChapter(title: "Conclusion",    startTime: 3000.0),  // 50:00
        ]

        // Hit at 872s (14:32) falls in "The Argument" (starts 600s).
        let resolved = SRTSearcher.resolveChapter(startSeconds: 872.0, chapters: chapters)
        #expect(resolved?.title == "The Argument")

        // Hit at 30s falls in "Introduction" (starts 0s).
        let intro = SRTSearcher.resolveChapter(startSeconds: 30.0, chapters: chapters)
        #expect(intro?.title == "Introduction")

        // Hit at 3001s falls in "Conclusion".
        let conclusion = SRTSearcher.resolveChapter(startSeconds: 3001.0, chapters: chapters)
        #expect(conclusion?.title == "Conclusion")

        // No chapters — returns nil.
        #expect(SRTSearcher.resolveChapter(startSeconds: 100.0, chapters: []) == nil)
    }

    // MARK: - testEstimateTokens

    @Test("estimateTokens returns wordCount × 1.3 rounded")
    func testEstimateTokens() {
        // 10 words → Int((10 × 1.3).rounded()) = 13
        let tenWords = "one two three four five six seven eight nine ten"
        #expect(SRTSearcher.estimateTokens(tenWords) == 13)

        // Empty string → 0
        #expect(SRTSearcher.estimateTokens("") == 0)

        // Single word → Int((1 × 1.3).rounded()) = 1
        #expect(SRTSearcher.estimateTokens("hello") == 1)
    }

    // MARK: - testMaxTokensBudget

    @Test("--max-tokens truncates RAG output deterministically by relevance")
    func testMaxTokensBudget() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        // Seed 5 videos, each with a unique matching block.
        for i in 1...5 {
            try await seedVideo(
                db: db,
                videoId: "https://youtube.com/watch?v=budget\(i)",
                title: "Budget Video \(i)",
                blocks: [
                    SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                             startSeconds: 1.0, endSeconds: 4.0,
                             text: "neural network optimization strategy \(i)"),
                ]
            )
        }

        let output = try await SRTSearcher.search(query: "neural network", db: db, limit: 50)
        #expect(output.totalMatches >= 5)

        // Tiny budget (1 token) forces truncation to 0 included hits
        // but renders at least the header.
        let tinyMarkdown = SRTSearcher.ragMarkdown(
            query: "neural network",
            results: output.results,
            totalBeforeBudget: output.totalMatches,
            maxTokens: 1
        )
        #expect(tinyMarkdown.contains("# Search Results:"))
        #expect(tinyMarkdown.contains("to fit max token budget (1)"))
        // Should have rendered 0 hits (every chunk exceeds 1 token).
        #expect(tinyMarkdown.contains("Included 0/"))

        // Large budget renders all hits without a footer.
        let fullMarkdown = SRTSearcher.ragMarkdown(
            query: "neural network",
            results: output.results,
            totalBeforeBudget: output.totalMatches,
            maxTokens: 100_000
        )
        #expect(!fullMarkdown.contains("to fit max token budget"))
        // All 5 hits are rendered.
        for i in 1...5 {
            #expect(fullMarkdown.contains("Budget Video \(i)"))
        }

        // No maxTokens → all hits rendered, no footer.
        let noCapMarkdown = SRTSearcher.ragMarkdown(
            query: "neural network",
            results: output.results,
            totalBeforeBudget: output.totalMatches
        )
        #expect(!noCapMarkdown.contains("to fit max token budget"))
        #expect(noCapMarkdown.contains("# Search Results:"))
    }

    // MARK: - testRAGMarkdownOutput

    @Test("--rag produces structured Markdown with attribution, clip commands, and context blocks")
    func testRAGMarkdownOutput() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let videoPath = "/Users/mike/.vvx/archive/YouTube/TestChan/video.mp4"
        try await seedVideo(
            db: db,
            videoId: "https://youtube.com/watch?v=rag1",
            title: "RAG Test Video",
            platform: "YouTube",
            uploader: "TestChan",
            uploadDate: "2026-01-20",
            videoPath: videoPath,
            blocks: [
                SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:05,000",
                         startSeconds: 1.0, endSeconds: 5.0, text: "Context before block."),
                SRTBlock(index: 2, startTime: "00:00:06,000", endTime: "00:00:10,000",
                         startSeconds: 6.0, endSeconds: 10.0,
                         text: "The matched quantum computing snippet here."),
                SRTBlock(index: 3, startTime: "00:00:11,000", endTime: "00:00:15,000",
                         startSeconds: 11.0, endSeconds: 15.0, text: "Context after block."),
            ]
        )

        let output = try await SRTSearcher.search(query: "quantum computing", db: db)
        #expect(output.totalMatches == 1)

        let markdown = SRTSearcher.ragMarkdown(
            query: "quantum computing",
            results: output.results,
            totalBeforeBudget: output.totalMatches,
            versionString: "0.3.0"
        )

        // Header
        #expect(markdown.contains("# Search Results: \"quantum computing\""))
        #expect(markdown.contains("generated by vvx 0.3.0"))

        // Hit heading: title — uploader (platform)
        #expect(markdown.contains("### Hit 1 of 1: RAG Test Video — TestChan (YouTube)"))

        // Metadata line
        #expect(markdown.contains("**Timestamp:** 00:00:06 – 00:00:10"))
        #expect(markdown.contains("**Uploaded:** 2026-01-20"))

        // File and clip command
        #expect(markdown.contains("**File:** `\(videoPath)`"))
        #expect(markdown.contains("**Clip:** `vvx clip \"\(videoPath)\" --start 00:00:06 --end 00:00:10`"))

        // Blockquote context with timestamps
        #expect(markdown.contains("> [00:00:01] Context before block."))
        // Matched block is bold
        #expect(markdown.contains("> **[00:00:06] The matched quantum computing snippet here.**"))
        #expect(markdown.contains("> [00:00:11] Context after block."))

        // No truncation footer when no maxTokens
        #expect(!markdown.contains("to fit max token budget"))
    }

    // MARK: - testRAGMarkdownChapterHeading

    @Test("--rag includes chapter heading when chapter data is available for the hit")
    func testRAGMarkdownChapterHeading() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let chapters = [
            VideoChapter(title: "The AGI Debate", startTime: 800.0),   // 13:20
        ]
        try await db.upsertVideo(VideoRecord(
            id:       "https://youtube.com/watch?v=ch1",
            title:    "Chapter Test",
            platform: "YouTube",
            uploader: "TestChan",
            sensedAt: "2026-01-01T00:00:00Z",
            chapters: chapters
        ))
        try await db.upsertBlocks(
            [SRTBlock(index: 1, startTime: "00:14:32,000", endTime: "00:14:47,000",
                      startSeconds: 872.0, endSeconds: 887.0,
                      text: "artificial general intelligence is near")],
            videoId:  "https://youtube.com/watch?v=ch1",
            title:    "Chapter Test",
            platform: "YouTube",
            uploader: "TestChan"
        )

        let output = try await SRTSearcher.search(query: "artificial general intelligence", db: db)
        #expect(output.totalMatches == 1)
        #expect(output.results[0].chapterTitle == "The AGI Debate")

        let markdown = SRTSearcher.ragMarkdown(
            query: "artificial general intelligence",
            results: output.results,
            totalBeforeBudget: output.totalMatches
        )
        #expect(markdown.contains("**Chapter:** \"The AGI Debate\""))
    }

    // MARK: - testSearchWithFilters

    @Test("--platform filter excludes videos from other platforms")
    func testSearchWithPlatformFilter() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        try await seedVideo(
            db: db, videoId: "https://youtube.com/watch?v=yt1",
            title: "YouTube Video", platform: "YouTube",
            blocks: [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                              startSeconds: 1.0, endSeconds: 4.0,
                              text: "neural networks are fascinating")]
        )
        try await seedVideo(
            db: db, videoId: "https://tiktok.com/@user/video/1",
            title: "TikTok Video", platform: "TikTok",
            blocks: [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                              startSeconds: 1.0, endSeconds: 4.0,
                              text: "neural networks are fascinating")]
        )

        let ytOutput = try await SRTSearcher.search(
            query: "neural networks", db: db, platform: "YouTube"
        )
        #expect(ytOutput.totalMatches == 1)
        #expect(ytOutput.results[0].platform == "YouTube")
    }

    @Test("--uploader filter excludes videos from other uploaders")
    func testSearchWithUploaderFilter() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        try await seedVideo(
            db: db, videoId: "https://youtube.com/watch?v=ul1",
            title: "Lex Video", platform: "YouTube", uploader: "Lex Fridman",
            blocks: [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                              startSeconds: 1.0, endSeconds: 4.0,
                              text: "consciousness is a fundamental mystery")]
        )
        try await seedVideo(
            db: db, videoId: "https://youtube.com/watch?v=ul2",
            title: "Other Video", platform: "YouTube", uploader: "Other Channel",
            blocks: [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                              startSeconds: 1.0, endSeconds: 4.0,
                              text: "consciousness is a fundamental mystery")]
        )

        let filtered = try await SRTSearcher.search(
            query: "consciousness", db: db, uploader: "Lex Fridman"
        )
        #expect(filtered.totalMatches == 1)
        #expect(filtered.results[0].uploader == "Lex Fridman")
    }

    // MARK: - testSearchOutputJSON

    @Test("SearchOutput encodes to valid JSON with required fields")
    func testSearchOutputJSON() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        try await seedVideo(
            db: db, videoId: "https://youtube.com/watch?v=json1",
            title: "JSON Test", videoPath: "/path/to/video.mp4",
            transcriptPath: "/path/to/video.srt",
            blocks: [SRTBlock(index: 1, startTime: "00:00:10,000", endTime: "00:00:14,000",
                              startSeconds: 10.0, endSeconds: 14.0,
                              text: "quantum computing will revolutionize cryptography")]
        )

        let output = try await SRTSearcher.search(query: "quantum computing", db: db)

        let json = output.jsonString()
        // Confirm the JSON envelope fields from §5.1 are present.
        #expect(json.contains("\"success\""))
        #expect(json.contains("\"query\""))
        #expect(json.contains("\"totalMatches\""))
        #expect(json.contains("\"results\""))
        #expect(json.contains("\"relevanceScore\""))
        #expect(json.contains("\"snippet\""))
        #expect(json.contains("\"contextBefore\""))
        #expect(json.contains("\"contextAfter\""))
        #expect(json.contains("\"videoPath\""))
        #expect(json.contains("\"transcriptPath\""))
        #expect(json.contains("\"timestamp\""))
        #expect(json.contains("\"timestampEnd\""))
        // Timestamps must be stripped of milliseconds.
        #expect(json.contains("\"00:00:10\""))
        #expect(!json.contains(",000"))
    }
}
