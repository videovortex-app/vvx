import Testing
import Foundation
@testable import VideoVortexCore

// MARK: - VortexDB Tests
// Covers every case listed in §13 of VVXPhase3Roadmap.md.
// All test methods are async because VortexDB is an actor.

@Suite("VortexDB")
struct VortexDBTests {

    // MARK: - Helpers

    /// Create an isolated VortexDB at a temp path that is deleted after the test.
    private func makeDB() async throws -> (VortexDB, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortex_test_\(UUID().uuidString).db")
        let db = try VortexDB(path: url)
        return (db, url)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - testInit

    @Test("Database initialises with correct schema tables")
    func testInit() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        // Schema version should be 4 after init (V1: base, V2: chapters, V3: chapter_index FTS5, V4: like_count/comment_count).
        let version = try await db.schemaVersion()
        #expect(version == 4)

        // videos table: should be queryable and empty.
        let videos = try await db.allVideos()
        #expect(videos.isEmpty)

        // integrity check should pass.
        let ok = try await db.integrity()
        #expect(ok)
    }

    // MARK: - testWALModeEnabled

    @Test("WAL journal mode is active after init")
    func testWALModeEnabled() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let mode = try await db.journalMode()
        #expect(mode == "wal")
    }

    // MARK: - testUpsertVideo

    @Test("upsertVideo inserts a new record")
    func testUpsertVideoInsert() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let record = VideoRecord(
            id:        "https://youtube.com/watch?v=abc",
            title:     "Test Video",
            platform:  "YouTube",
            uploader:  "Test Channel",
            sensedAt:  "2026-03-25T10:00:00Z"
        )
        try await db.upsertVideo(record)

        let all = try await db.allVideos()
        #expect(all.count == 1)
        #expect(all[0].id    == "https://youtube.com/watch?v=abc")
        #expect(all[0].title == "Test Video")
    }

    @Test("upsertVideo updates an existing record on conflict")
    func testUpsertVideoUpdate() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let v1 = VideoRecord(
            id: "https://youtube.com/watch?v=abc",
            title: "Original Title",
            sensedAt: "2026-03-25T10:00:00Z"
        )
        try await db.upsertVideo(v1)

        let v2 = VideoRecord(
            id:    "https://youtube.com/watch?v=abc",
            title: "Updated Title",
            platform: "YouTube",
            sensedAt: "2026-03-25T11:00:00Z"
        )
        try await db.upsertVideo(v2)

        let all = try await db.allVideos()
        #expect(all.count == 1)           // still one row
        #expect(all[0].title == "Updated Title")
        #expect(all[0].platform == "YouTube")
    }

    @Test("upsertVideo preserves existing videoPath when new record has nil videoPath")
    func testUpsertVideoPreservesVideoPath() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        // First upsert: with a videoPath.
        let v1 = VideoRecord(
            id:        "https://youtube.com/watch?v=xyz",
            title:     "Video with File",
            videoPath: "/home/user/.vvx/archive/video.mp4",
            sensedAt:  "2026-03-25T10:00:00Z"
        )
        try await db.upsertVideo(v1)

        // Second upsert: re-sense, no videoPath.
        let v2 = VideoRecord(
            id:      "https://youtube.com/watch?v=xyz",
            title:   "Video with File (re-sensed)",
            sensedAt: "2026-03-25T12:00:00Z"
        )
        try await db.upsertVideo(v2)

        let all = try await db.allVideos()
        // videoPath from the first insert must be preserved.
        #expect(all[0].videoPath == "/home/user/.vvx/archive/video.mp4")
    }

    // MARK: - testDeduplication

    @Test("Upserting the same URL twice results in exactly one row")
    func testDeduplication() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        for i in 1...3 {
            let r = VideoRecord(
                id: "https://youtube.com/watch?v=dup",
                title: "Duplicate \(i)",
                sensedAt: "2026-03-25T10:00:0\(i)Z"
            )
            try await db.upsertVideo(r)
        }
        let all = try await db.allVideos()
        #expect(all.count == 1)
        #expect(all[0].title == "Duplicate 3")
    }

    // MARK: - testUpsertBlocks

    @Test("upsertBlocks stores all SRTBlocks for a video")
    func testUpsertBlocks() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let videoId = "https://youtube.com/watch?v=blocks"
        try await db.upsertVideo(VideoRecord(id: videoId, title: "Block Video", sensedAt: "2026-01-01T00:00:00Z"))

        let blocks = [
            SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                     startSeconds: 1.0, endSeconds: 4.0, text: "Hello world."),
            SRTBlock(index: 2, startTime: "00:00:05,000", endTime: "00:00:08,000",
                     startSeconds: 5.0, endSeconds: 8.0, text: "Second subtitle."),
        ]
        try await db.upsertBlocks(blocks, videoId: videoId, title: "Block Video",
                                  platform: "YouTube", uploader: "TestChannel")

        let stored = try await db.blocksForVideo(videoId: videoId)
        #expect(stored.count == 2)
        #expect(stored[0].text == "Hello world.")
        #expect(stored[1].text == "Second subtitle.")
    }

    @Test("upsertBlocks replaces old blocks on re-index")
    func testUpsertBlocksReplaces() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let videoId = "https://youtube.com/watch?v=replace"
        try await db.upsertVideo(VideoRecord(id: videoId, title: "V", sensedAt: "2026-01-01T00:00:00Z"))

        // Insert first set (3 blocks).
        let first = (1...3).map { i in
            SRTBlock(index: i, startTime: "00:00:0\(i),000", endTime: "00:00:0\(i+1),000",
                     startSeconds: Double(i), endSeconds: Double(i+1), text: "Block \(i)")
        }
        try await db.upsertBlocks(first, videoId: videoId, title: "V", platform: nil, uploader: nil)

        // Re-index with only 1 block (simulating re-sense).
        let second = [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                               startSeconds: 1.0, endSeconds: 4.0, text: "Fresh block.")]
        try await db.upsertBlocks(second, videoId: videoId, title: "V", platform: nil, uploader: nil)

        let stored = try await db.blocksForVideo(videoId: videoId)
        #expect(stored.count == 1)
        #expect(stored[0].text == "Fresh block.")
    }

    // MARK: - testSearch

    @Test("FTS5 MATCH returns the correct block")
    func testSearch() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let videoId = "https://youtube.com/watch?v=search1"
        try await db.upsertVideo(VideoRecord(id: videoId, title: "AI Podcast", platform: "YouTube",
                                             sensedAt: "2026-01-01T00:00:00Z"))
        let blocks = [
            SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                     startSeconds: 1.0, endSeconds: 4.0, text: "Today we talk about artificial intelligence."),
            SRTBlock(index: 2, startTime: "00:00:05,000", endTime: "00:00:08,000",
                     startSeconds: 5.0, endSeconds: 8.0, text: "The weather is nice today."),
        ]
        try await db.upsertBlocks(blocks, videoId: videoId, title: "AI Podcast",
                                  platform: "YouTube", uploader: "Host")

        let hits = try await db.search(query: "artificial intelligence")
        #expect(hits.count == 1)
        #expect(hits[0].text.contains("artificial intelligence"))
        #expect(hits[0].videoId == videoId)
    }

    @Test("FTS5 returns zero results for a non-matching query")
    func testSearchNoResults() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let videoId = "https://youtube.com/watch?v=empty"
        try await db.upsertVideo(VideoRecord(id: videoId, title: "V", sensedAt: "2026-01-01T00:00:00Z"))
        let blocks = [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                               startSeconds: 1.0, endSeconds: 4.0, text: "nothing relevant here")]
        try await db.upsertBlocks(blocks, videoId: videoId, title: "V", platform: nil, uploader: nil)

        let hits = try await db.search(query: "xylophone zigzag")
        #expect(hits.isEmpty)
    }

    @Test("FTS5 search result includes relevanceScore")
    func testSearchRelevanceScore() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let videoId = "https://youtube.com/watch?v=rank"
        try await db.upsertVideo(VideoRecord(id: videoId, title: "V", sensedAt: "2026-01-01T00:00:00Z"))
        let blocks = [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                               startSeconds: 1.0, endSeconds: 4.0, text: "machine learning is fascinating")]
        try await db.upsertBlocks(blocks, videoId: videoId, title: "V", platform: nil, uploader: nil)

        let hits = try await db.search(query: "machine learning")
        #expect(!hits.isEmpty)
        // bm25 scores are negative; a real match has a non-zero score.
        #expect(hits[0].relevanceScore != 0.0)
    }

    // MARK: - testBooleanSearch

    @Test("FTS5 boolean AND returns only blocks containing both terms")
    func testBooleanSearch() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let videoId = "https://youtube.com/watch?v=bool"
        try await db.upsertVideo(VideoRecord(id: videoId, title: "V", sensedAt: "2026-01-01T00:00:00Z"))
        let blocks = [
            SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                     startSeconds: 1.0, endSeconds: 4.0,
                     text: "AI is dangerous and powerful"),          // both terms
            SRTBlock(index: 2, startTime: "00:00:05,000", endTime: "00:00:08,000",
                     startSeconds: 5.0, endSeconds: 8.0,
                     text: "AI is interesting"),                     // only one term
            SRTBlock(index: 3, startTime: "00:00:09,000", endTime: "00:00:12,000",
                     startSeconds: 9.0, endSeconds: 12.0,
                     text: "danger lurks everywhere"),               // only the other term
        ]
        try await db.upsertBlocks(blocks, videoId: videoId, title: "V", platform: nil, uploader: nil)

        let hits = try await db.search(query: "AI AND dangerous")
        #expect(hits.count == 1)
        #expect(hits[0].text.contains("AI"))
        #expect(hits[0].text.contains("dangerous"))
    }

    // MARK: - testSearchStemming

    @Test("FTS5 Porter stemmer: 'run' matches 'running'")
    func testSearchStemming() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let videoId = "https://youtube.com/watch?v=stem"
        try await db.upsertVideo(VideoRecord(id: videoId, title: "V", sensedAt: "2026-01-01T00:00:00Z"))
        let blocks = [
            SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                     startSeconds: 1.0, endSeconds: 4.0,
                     text: "He is running every morning."),
        ]
        try await db.upsertBlocks(blocks, videoId: videoId, title: "V", platform: nil, uploader: nil)

        // Searching the stem "run" should match the stored word "running".
        let hits = try await db.search(query: "run")
        #expect(!hits.isEmpty)
    }

    // MARK: - testSearchWithFilters

    @Test("search --platform filter returns only matching platform")
    func testSearchPlatformFilter() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        for (vid, platform) in [("v1", "YouTube"), ("v2", "TikTok")] {
            try await db.upsertVideo(VideoRecord(
                id: "https://\(platform.lowercased()).com/\(vid)",
                title: "Test Video", platform: platform,
                sensedAt: "2026-01-01T00:00:00Z"
            ))
            let blocks = [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:03,000",
                                   startSeconds: 1, endSeconds: 3, text: "test content about robots")]
            try await db.upsertBlocks(blocks,
                videoId: "https://\(platform.lowercased()).com/\(vid)",
                title: "Test Video", platform: platform, uploader: nil)
        }

        let hits = try await db.search(query: "robots", platform: "YouTube")
        #expect(hits.count == 1)
        #expect(hits[0].platform == "YouTube")
    }

    @Test("search --after date filter excludes older videos")
    func testSearchAfterDateFilter() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        // Old video (2025).
        try await db.upsertVideo(VideoRecord(
            id: "https://youtube.com/old", title: "Old Video",
            uploadDate: "2025-01-15", sensedAt: "2026-01-01T00:00:00Z"
        ))
        // New video (2026).
        try await db.upsertVideo(VideoRecord(
            id: "https://youtube.com/new", title: "New Video",
            uploadDate: "2026-03-01", sensedAt: "2026-03-01T00:00:00Z"
        ))

        for (videoId, _) in [("https://youtube.com/old", "2025"), ("https://youtube.com/new", "2026")] {
            let blocks = [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:03,000",
                                   startSeconds: 1, endSeconds: 3, text: "spacecraft launch event")]
            try await db.upsertBlocks(blocks, videoId: videoId, title: "T", platform: nil, uploader: nil)
        }

        let hits = try await db.search(query: "spacecraft", afterDate: "2026-01-01")
        #expect(hits.count == 1)
        #expect(hits[0].videoId == "https://youtube.com/new")
    }

    // MARK: - testIntegrityCheck

    @Test("integrity() returns true for a freshly created database")
    func testIntegrityCheck() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let ok = try await db.integrity()
        #expect(ok)
    }

    // MARK: - testSqlReadOnlySelect

    @Test("executeReadOnly allows SELECT and returns rows")
    func testReadOnlySelect() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        try await db.upsertVideo(VideoRecord(
            id: "https://youtube.com/watch?v=sql",
            title: "SQL Test Video", platform: "YouTube",
            sensedAt: "2026-01-01T00:00:00Z"
        ))

        let rows = try await db.executeReadOnly(
            "SELECT id, title FROM videos WHERE platform = 'YouTube';"
        )
        #expect(rows.count == 1)
        #expect(rows[0]["title"] == "SQL Test Video")
    }

    @Test("executeReadOnly rejects INSERT statement")
    func testReadOnlyRejectsInsert() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        await #expect(throws: VortexDBError.notReadOnly) {
            try await db.executeReadOnly("INSERT INTO videos(id,title,sensed_at) VALUES('x','y','z');")
        }
    }

    @Test("executeReadOnly rejects DROP statement")
    func testReadOnlyRejectsDrop() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        await #expect(throws: VortexDBError.notReadOnly) {
            try await db.executeReadOnly("DROP TABLE videos;")
        }
    }

    // MARK: - testConcurrentWrites

    @Test("Three concurrent upserts all succeed (actor serialisation)")
    func testConcurrentWrites() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        // Fire 3 concurrent upsert tasks and await all.
        await withTaskGroup(of: Void.self) { group in
            for i in 1...3 {
                group.addTask {
                    let record = VideoRecord(
                        id:      "https://youtube.com/watch?v=concurrent\(i)",
                        title:   "Concurrent Video \(i)",
                        sensedAt: "2026-03-25T10:00:0\(i)Z"
                    )
                    try? await db.upsertVideo(record)

                    let blocks = [SRTBlock(
                        index: 1,
                        startTime: "00:00:01,000", endTime: "00:00:04,000",
                        startSeconds: 1.0, endSeconds: 4.0,
                        text: "Concurrent transcript block \(i)"
                    )]
                    try? await db.upsertBlocks(
                        blocks,
                        videoId: "https://youtube.com/watch?v=concurrent\(i)",
                        title: "Concurrent Video \(i)",
                        platform: nil, uploader: nil
                    )
                }
            }
        }

        // All 3 videos and their blocks must be present.
        let all = try await db.allVideos()
        #expect(all.count == 3)

        for i in 1...3 {
            let stored = try await db.blocksForVideo(
                videoId: "https://youtube.com/watch?v=concurrent\(i)"
            )
            #expect(stored.count == 1)
        }
    }

    // MARK: - videoCount

    @Test("videoCount returns the correct count")
    func testVideoCount() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        #expect(try await db.videoCount() == 0)

        for i in 1...5 {
            try await db.upsertVideo(VideoRecord(
                id: "https://youtube.com/watch?v=\(i)",
                title: "Video \(i)",
                sensedAt: "2026-01-01T00:00:0\(i)Z"
            ))
        }

        #expect(try await db.videoCount() == 5)
    }

    @Test("latestSensedAt returns the lexicographic maximum sensed_at")
    func testLatestSensedAt() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        #expect(try await db.latestSensedAt() == nil)

        try await db.upsertVideo(VideoRecord(
            id: "https://youtube.com/watch?v=a",
            title: "A",
            sensedAt: "2026-01-01T10:00:00Z"
        ))
        try await db.upsertVideo(VideoRecord(
            id: "https://youtube.com/watch?v=b",
            title: "B",
            sensedAt: "2026-03-26T15:00:00Z"
        ))

        #expect(try await db.latestSensedAt() == "2026-03-26T15:00:00Z")
    }

    @Test("totalDurationSeconds sums duration_seconds")
    func testTotalDurationSeconds() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        #expect(try await db.totalDurationSeconds() == 0)

        try await db.upsertVideo(VideoRecord(
            id: "https://youtube.com/watch?v=x",
            title: "X",
            durationSeconds: 1800,
            sensedAt: "2026-01-01T00:00:00Z"
        ))
        try await db.upsertVideo(VideoRecord(
            id: "https://youtube.com/watch?v=y",
            title: "Y",
            durationSeconds: 3600,
            sensedAt: "2026-01-02T00:00:00Z"
        ))

        #expect(try await db.totalDurationSeconds() == 5400)
    }

    // MARK: - blocksForVideo ordering

    @Test("blocksForVideo returns blocks ordered by startSeconds ascending")
    func testBlocksOrdering() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let videoId = "https://youtube.com/watch?v=order"
        try await db.upsertVideo(VideoRecord(id: videoId, title: "V", sensedAt: "2026-01-01T00:00:00Z"))

        // Insert out of order.
        let blocks = [
            SRTBlock(index: 3, startTime: "00:00:09,000", endTime: "00:00:12,000",
                     startSeconds: 9.0, endSeconds: 12.0, text: "Third block"),
            SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                     startSeconds: 1.0, endSeconds: 4.0,  text: "First block"),
            SRTBlock(index: 2, startTime: "00:00:05,000", endTime: "00:00:08,000",
                     startSeconds: 5.0, endSeconds: 8.0,  text: "Second block"),
        ]
        try await db.upsertBlocks(blocks, videoId: videoId, title: "V", platform: nil, uploader: nil)

        let stored = try await db.blocksForVideo(videoId: videoId)
        #expect(stored.count == 3)
        #expect(stored[0].text == "First block")
        #expect(stored[1].text == "Second block")
        #expect(stored[2].text == "Third block")
    }

    // MARK: - Step 3: SearchHit fields (chapterIndex, videoDurationSeconds)

    @Test("search returns chapterIndex and videoDurationSeconds on hits")
    func testSearchHitStep3Fields() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let videoId = "https://youtube.com/watch?v=step3fields"
        try await db.upsertVideo(VideoRecord(
            id: videoId, title: "Step3 Fields", durationSeconds: 600,
            sensedAt: "2026-01-01T00:00:00Z"
        ))
        let blocks = [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                               startSeconds: 1.0, endSeconds: 4.0, text: "quantum computing is here")]
        try await db.upsertBlocks(blocks, videoId: videoId, title: "Step3 Fields",
                                  platform: "YouTube", uploader: nil)

        let hits = try await db.search(query: "quantum computing")
        #expect(hits.count == 1)
        // videoDurationSeconds flows from the JOIN.
        #expect(hits[0].videoDurationSeconds == 600)
        // chapterIndex is nil for blocks inserted without chapter backfill.
        #expect(hits[0].chapterIndex == nil)
    }

    // MARK: - Step 3: engagement filter inside SQL (LIMIT applies after filters)

    @Test("search minViews excludes videos below threshold and respects LIMIT")
    func testSearchMinViewsInSQL() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        // Video A: 500k views (below threshold).
        let vidA = "https://youtube.com/watch?v=lowviews"
        try await db.upsertVideo(VideoRecord(
            id: vidA, title: "Low Views", sensedAt: "2026-01-01T00:00:00Z",
            viewCount: 500_000
        ))
        let blocksA = (1...5).map { i in
            SRTBlock(index: i,
                     startTime: "00:00:0\(i),000", endTime: "00:00:0\(i+1),000",
                     startSeconds: Double(i), endSeconds: Double(i+1),
                     text: "robots are taking over \(i)")
        }
        try await db.upsertBlocks(blocksA, videoId: vidA, title: "Low Views", platform: nil, uploader: nil)

        // Video B: 2M views (above threshold).
        let vidB = "https://youtube.com/watch?v=highviews"
        try await db.upsertVideo(VideoRecord(
            id: vidB, title: "High Views", sensedAt: "2026-01-01T00:00:00Z",
            viewCount: 2_000_000
        ))
        let blocksB = (1...5).map { i in
            SRTBlock(index: i,
                     startTime: "00:01:0\(i),000", endTime: "00:01:0\(i+1),000",
                     startSeconds: Double(60 + i), endSeconds: Double(61 + i),
                     text: "robots are taking over \(i+10)")
        }
        try await db.upsertBlocks(blocksB, videoId: vidB, title: "High Views", platform: nil, uploader: nil)

        // With --limit 10 and --min-views 1_000_000:
        // Should return only hits from vidB (5 blocks), not the 5 from vidA.
        let hits = try await db.search(query: "robots", minViews: 1_000_000, limit: 10)
        #expect(!hits.isEmpty)
        for h in hits {
            #expect(h.videoId == vidB)
        }
    }

    @Test("search minViews passes NULL view_count rows (conservative)")
    func testSearchMinViewsPassesNullViewCount() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        // Video with no view_count (nil = not scraped).
        let vidNull = "https://youtube.com/watch?v=nullviews"
        try await db.upsertVideo(VideoRecord(
            id: vidNull, title: "Null Views", sensedAt: "2026-01-01T00:00:00Z"
            // viewCount intentionally omitted (nil)
        ))
        let blocks = [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                               startSeconds: 1.0, endSeconds: 4.0, text: "machine learning advances")]
        try await db.upsertBlocks(blocks, videoId: vidNull, title: "Null Views", platform: nil, uploader: nil)

        // Even with a very high --min-views, null rows must still pass.
        let hits = try await db.search(query: "machine learning", minViews: 10_000_000)
        #expect(hits.count == 1)
        #expect(hits[0].videoId == vidNull)
    }

    @Test("search minLikes and minComments filter correctly")
    func testSearchEngagementLikesComments() async throws {
        let (db, url) = try await makeDB()
        defer { cleanup(url) }

        let vidGood = "https://youtube.com/watch?v=goodengage"
        try await db.upsertVideo(VideoRecord(
            id: vidGood, title: "Good Engage", sensedAt: "2026-01-01T00:00:00Z",
            likeCount: 10_000, commentCount: 500
        ))
        try await db.upsertBlocks(
            [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                      startSeconds: 1.0, endSeconds: 4.0, text: "space exploration plans")],
            videoId: vidGood, title: "Good Engage", platform: nil, uploader: nil)

        let vidBad = "https://youtube.com/watch?v=badengage"
        try await db.upsertVideo(VideoRecord(
            id: vidBad, title: "Bad Engage", sensedAt: "2026-01-01T00:00:00Z",
            likeCount: 10, commentCount: 1
        ))
        try await db.upsertBlocks(
            [SRTBlock(index: 1, startTime: "00:00:01,000", endTime: "00:00:04,000",
                      startSeconds: 1.0, endSeconds: 4.0, text: "space exploration plans")],
            videoId: vidBad, title: "Bad Engage", platform: nil, uploader: nil)

        let hits = try await db.search(
            query: "space exploration",
            minLikes: 1_000,
            minComments: 100
        )
        #expect(hits.count == 1)
        #expect(hits[0].videoId == vidGood)
    }
}
