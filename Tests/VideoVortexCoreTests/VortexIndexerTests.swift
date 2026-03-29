import Testing
import Foundation
@testable import VideoVortexCore

// MARK: - VortexIndexer Tests
//
// Covers every integration point and the concurrency safety requirement from
// §16 of VVXPhase3Roadmap.md: "3 concurrent VortexIndexer writes in a test
// complete without SQLITE_BUSY error."

@Suite("VortexIndexer")
struct VortexIndexerTests {

    // MARK: - Helpers

    private func makeDB() throws -> (VortexDB, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortexindexer_test_\(UUID().uuidString).db")
        let db = try VortexDB(path: url)
        return (db, url)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        // Also remove WAL shim files
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))
    }

    /// Write a minimal SRT file to a temp path and return the path.
    private func makeSRTFile(blocks: Int = 3) throws -> String {
        var lines: [String] = []
        for i in 1...blocks {
            let start = i - 1
            let end   = i
            lines.append("\(i)")
            lines.append(String(format: "00:00:%02d,000 --> 00:00:%02d,000", start, end))
            lines.append("Block \(i) text here.")
            lines.append("")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).srt")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func makeSenseResult(url: String = "https://example.com/v1",
                                  srtPath: String? = nil) -> SenseResult {
        SenseResult(
            url:             url,
            title:           "Test Video",
            platform:        "YouTube",
            uploader:        "TestChannel",
            durationSeconds: 120,
            uploadDate:      "2026-01-15",
            description:     "A test video.",
            tags:            ["test", "video"],
            viewCount:       999,
            transcriptPath:  srtPath,
            transcriptLanguage: srtPath != nil ? "en" : nil,
            estimatedTokens: nil,
            chapters:        [],
            completedAt:     Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeVideoMetadata(url: String = "https://example.com/v2",
                                    srtPath: String? = nil) -> VideoMetadata {
        VideoMetadata(
            url:           url,
            title:         "Downloaded Video",
            platform:      "YouTube",
            durationSeconds: 300,
            fileSize:      1_000_000,
            outputPath:    "/tmp/video.mp4",
            subtitlePaths: srtPath.map { [$0] } ?? [],
            format:        .bestVideo,
            isArchiveMode: true,
            completedAt:   Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - testIndexSenseResult

    @Test("index(senseResult:db:) writes video record and transcript blocks")
    func testIndexSenseResult() async throws {
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let srtPath = try makeSRTFile(blocks: 3)
        defer { try? FileManager.default.removeItem(atPath: srtPath) }

        let result = makeSenseResult(srtPath: srtPath)
        try await VortexIndexer.index(senseResult: result, db: db)

        // Video record written.
        let videos = try await db.allVideos()
        #expect(videos.count == 1)
        let v = try #require(videos.first)
        #expect(v.id       == "https://example.com/v1")
        #expect(v.title    == "Test Video")
        #expect(v.platform == "YouTube")
        #expect(v.uploader == "TestChannel")
        #expect(v.videoPath == nil)          // sense-only: no media file
        #expect(v.archivedAt == nil)         // sense-only: not archived
        #expect(v.transcriptPath == srtPath)

        // Transcript blocks written.
        let blocks = try await db.blocksForVideo(videoId: "https://example.com/v1")
        #expect(blocks.count == 3)
        #expect(blocks[0].text == "Block 1 text here.")
    }

    // MARK: - testIndexSenseResultNoTranscript

    @Test("index(senseResult:db:) with nil transcriptPath stores video but zero blocks")
    func testIndexSenseResultNoTranscript() async throws {
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let result = makeSenseResult(srtPath: nil)
        try await VortexIndexer.index(senseResult: result, db: db)

        let videos = try await db.allVideos()
        #expect(videos.count == 1)
        #expect(videos[0].transcriptPath == nil)

        let blocks = try await db.blocksForVideo(videoId: "https://example.com/v1")
        #expect(blocks.isEmpty)
    }

    // MARK: - testIndexIdempotency

    @Test("Re-indexing the same URL replaces blocks rather than appending")
    func testIndexIdempotency() async throws {
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let srtPath = try makeSRTFile(blocks: 3)
        defer { try? FileManager.default.removeItem(atPath: srtPath) }

        let result = makeSenseResult(srtPath: srtPath)

        // Index twice.
        try await VortexIndexer.index(senseResult: result, db: db)
        try await VortexIndexer.index(senseResult: result, db: db)

        let videos = try await db.allVideos()
        #expect(videos.count == 1, "Re-sense must not duplicate the video record")

        let blocks = try await db.blocksForVideo(videoId: "https://example.com/v1")
        #expect(blocks.count == 3, "Re-sense must not duplicate transcript blocks")
    }

    // MARK: - testIndexMetadata

    @Test("index(metadata:db:) writes video record with videoPath and archivedAt set")
    func testIndexMetadata() async throws {
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let srtPath = try makeSRTFile(blocks: 4)
        defer { try? FileManager.default.removeItem(atPath: srtPath) }

        let meta = makeVideoMetadata(srtPath: srtPath)
        try await VortexIndexer.index(metadata: meta, db: db)

        let videos = try await db.allVideos()
        #expect(videos.count == 1)
        let v = try #require(videos.first)
        #expect(v.id            == "https://example.com/v2")
        #expect(v.videoPath     == "/tmp/video.mp4")
        #expect(v.archivedAt    != nil)      // downloaded → archived
        #expect(v.transcriptPath == srtPath)

        let blocks = try await db.blocksForVideo(videoId: "https://example.com/v2")
        #expect(blocks.count == 4)
    }

    // MARK: - testIndexMetadataNoSubtitles

    @Test("index(metadata:db:) with empty subtitlePaths stores video but zero blocks")
    func testIndexMetadataNoSubtitles() async throws {
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let meta = makeVideoMetadata(srtPath: nil)
        try await VortexIndexer.index(metadata: meta, db: db)

        let videos = try await db.allVideos()
        #expect(videos.count == 1)
        #expect(videos[0].transcriptPath == nil)

        let blocks = try await db.blocksForVideo(videoId: "https://example.com/v2")
        #expect(blocks.isEmpty)
    }

    // MARK: - testDiscoverArchived (Step 13 — DR smoke test)
    //
    // Creates a minimal on-disk fixture (one .info.json + one .srt) and verifies that
    // VortexIndexer.discoverArchived rebuilds the DB from scratch — covering the
    // `rm ~/.vvx/vortex.db && vvx reindex` disaster-recovery path.
    //
    // This test is intentionally simple and self-contained so it runs on Linux / Docker
    // (CI) without any network access or real media files.

    /// Write a minimal yt-dlp `.info.json` sidecar into `folder`.
    private func makeInfoJSON(in folder: URL, url: String, title: String, likeCount: Int, commentCount: Int) throws {
        let json: [String: Any] = [
            "webpage_url":   url,
            "title":         title,
            "uploader":      "TestChannel",
            "extractor_key": "youtube",
            "duration":      120.0,
            "upload_date":   "20260101",
            "view_count":    9999,
            "like_count":    likeCount,
            "comment_count": commentCount,
            "chapters": [
                ["title": "Intro", "start_time": 0.0,  "end_time": 60.0],
                ["title": "Main",  "start_time": 60.0, "end_time": 120.0]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        try data.write(to: folder.appendingPathComponent("\(title).info.json"))
    }

    @Test("discoverArchived imports .info.json + SRT with chapter_index and engagement counts")
    func testDiscoverArchived() async throws {
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        // Build a minimal archive tree: archiveRoot/YouTube/TestChannel/MyVideo/
        let archiveRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvx_archive_\(UUID().uuidString)", isDirectory: true)
        let videoFolder = archiveRoot
            .appendingPathComponent("YouTube/TestChannel/MyVideo", isDirectory: true)
        try FileManager.default.createDirectory(at: videoFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: archiveRoot) }

        let videoURL = "https://www.youtube.com/watch?v=testDiscover"

        // Write .info.json
        try makeInfoJSON(in: videoFolder, url: videoURL, title: "MyVideo", likeCount: 42, commentCount: 7)

        // Write a 3-block SRT with two chapters (blocks 1–2 in chapter 0, block 3 in chapter 1)
        let srt = """
            1
            00:00:10,000 --> 00:00:20,000
            Block one — in Intro chapter.

            2
            00:00:30,000 --> 00:00:40,000
            Block two — still in Intro chapter.

            3
            00:01:05,000 --> 00:01:15,000
            Block three — in Main chapter.

            """
        try srt.write(to: videoFolder.appendingPathComponent("MyVideo.en.srt"),
                      atomically: true, encoding: .utf8)

        // Run discovery against an empty DB.
        let (discovered, skipped) = try await VortexIndexer.discoverArchived(
            in: archiveRoot, db: db, force: false
        )

        #expect(discovered == 1, "Expected 1 discovered video")
        #expect(skipped    == 0, "Expected 0 skipped")

        // VideoRecord assertions.
        let videos = try await db.allVideos()
        #expect(videos.count == 1)
        let v = try #require(videos.first)
        #expect(v.id           == videoURL)
        #expect(v.title        == "MyVideo")
        #expect(v.platform     == "YouTube")
        #expect(v.uploader     == "TestChannel")
        #expect(v.likeCount    == 42)
        #expect(v.commentCount == 7)
        #expect(v.uploadDate   == "2026-01-01")
        #expect(v.archivedAt   != nil)

        // Transcript block count.
        let blocks = try await db.blocksForVideo(videoId: videoURL)
        #expect(blocks.count == 3)

        // Verify chapter_index values via executeReadOnly (StoredBlock doesn't expose chapterIndex).
        // Blocks at 10s and 30s fall in chapter 0 (Intro: 0–60s).
        // Block at 65s falls in chapter 1 (Main: 60–120s).
        let escapedURL = videoURL.replacingOccurrences(of: "'", with: "''")
        let rows = try await db.executeReadOnly(
            "SELECT chapter_index FROM transcript_blocks WHERE video_id = '\(escapedURL)' ORDER BY start_seconds ASC;"
        )
        let indices = rows.compactMap { $0["chapter_index"] ?? nil }.compactMap { Int($0 ?? "") }
        #expect(indices == [0, 0, 1], "chapter_index should be [0, 0, 1] for blocks at 10s, 30s, 65s")
    }

    @Test("discoverArchived skips videos already in DB (idempotency)")
    func testDiscoverArchivedSkipsExisting() async throws {
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let archiveRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvx_archive_\(UUID().uuidString)", isDirectory: true)
        let videoFolder = archiveRoot
            .appendingPathComponent("YouTube/TestChannel/ExistingVideo", isDirectory: true)
        try FileManager.default.createDirectory(at: videoFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: archiveRoot) }

        let videoURL = "https://www.youtube.com/watch?v=existingVideo"
        try makeInfoJSON(in: videoFolder, url: videoURL, title: "ExistingVideo", likeCount: 1, commentCount: 0)

        // Pre-insert the record so it's already indexed.
        let existing = VideoRecord(id: videoURL, title: "ExistingVideo", sensedAt: "2026-01-01T00:00:00Z")
        try await db.upsertVideo(existing)

        let (discovered, skipped) = try await VortexIndexer.discoverArchived(
            in: archiveRoot, db: db, force: false
        )

        #expect(discovered == 0, "Should skip already-indexed video")
        #expect(skipped    == 1)

        // With --force it should re-import.
        let (discForced, _) = try await VortexIndexer.discoverArchived(
            in: archiveRoot, db: db, force: true
        )
        #expect(discForced == 1, "--force should re-import the video")
    }

    // MARK: - testConcurrentIndexing

    /// Roadmap §16 exit criterion: 3 simultaneous VortexIndexer writes against the
    /// same DB must all succeed.  WAL + busy_timeout=5000 prevent SQLITE_BUSY.
    @Test("3 concurrent VortexIndexer writes complete without SQLITE_BUSY")
    func testConcurrentIndexing() async throws {
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        // Three distinct SRT files so each write covers a different video.
        let srt1 = try makeSRTFile(blocks: 5)
        let srt2 = try makeSRTFile(blocks: 5)
        let srt3 = try makeSRTFile(blocks: 5)
        defer {
            try? FileManager.default.removeItem(atPath: srt1)
            try? FileManager.default.removeItem(atPath: srt2)
            try? FileManager.default.removeItem(atPath: srt3)
        }

        let r1 = makeSenseResult(url: "https://example.com/c1", srtPath: srt1)
        let r2 = makeSenseResult(url: "https://example.com/c2", srtPath: srt2)
        let r3 = makeSenseResult(url: "https://example.com/c3", srtPath: srt3)

        // Fire all three concurrently via a TaskGroup.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await VortexIndexer.index(senseResult: r1, db: db) }
            group.addTask { try await VortexIndexer.index(senseResult: r2, db: db) }
            group.addTask { try await VortexIndexer.index(senseResult: r3, db: db) }
            try await group.waitForAll()
        }

        let videos = try await db.allVideos()
        #expect(videos.count == 3, "All 3 concurrent writes must have succeeded")

        for url in ["https://example.com/c1", "https://example.com/c2", "https://example.com/c3"] {
            let blocks = try await db.blocksForVideo(videoId: url)
            #expect(blocks.count == 5, "Each video should have 5 blocks after concurrent write")
        }
    }
}
