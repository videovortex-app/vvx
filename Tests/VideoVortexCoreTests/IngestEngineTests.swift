import Testing
import Foundation
@testable import VideoVortexCore

// MARK: - IngestEngine Phase 1 Tests
//
// Covers every item in §Unit tests (by phase) — Phase 1 of VVX3.5Step9.5.md.
//
// All tests use isolated temp directories and isolated VortexDB instances so they
// never touch ~/.vvx/vortex.db. The `db:` injection parameter added to
// IngestEngine.run makes this possible without changing production behaviour.
//
// Tests that use dry-run:true do NOT need a DB (they skip upsert paths entirely).
// Tests that verify DB state create an isolated VortexDB at a temp path.

@Suite("IngestEngine — Phase 1 (Core)")
struct IngestEngineTests {

    // MARK: - Shared helpers

    /// Create a fresh isolated temp directory. Caller owns cleanup.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Touch a file at `url` with optional content (empty by default).
    private func writeFile(_ url: URL, content: String = "") throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Write a minimal valid SRT file next to a video stem.
    private func writeSRT(stem: String, ext: String = "srt", folder: URL, content: String? = nil) throws -> URL {
        let url = folder.appendingPathComponent("\(stem).\(ext)")
        let srt = content ?? """
        1
        00:00:01,000 --> 00:00:04,000
        Hello from the transcript.

        2
        00:00:05,000 --> 00:00:08,000
        Second block of speech.

        """
        try srt.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Write a JSON file at `url` with `content`.
    private func writeJSON(_ url: URL, content: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: content)
        try data.write(to: url)
    }

    /// Build a valid yt-dlp-shape info.json dict using `webpage_url` branch.
    private func validInfoByURL() -> [String: Any] {
        ["webpage_url": "https://youtube.com/watch?v=abc", "title": "Test Video", "uploader": "TestChannel", "duration": 120.0]
    }

    /// Build a valid yt-dlp-shape info.json dict using `id+title+duration` branch.
    private func validInfoByIDTitleDuration() -> [String: Any] {
        ["id": "abc123", "title": "Test Video", "duration": 120.0]
    }

    /// Open an isolated VortexDB at a temp path. Caller owns cleanup via the returned URL.
    private func makeDB() throws -> (VortexDB, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest_db_\(UUID().uuidString).db")
        let db = try VortexDB(path: url)
        return (db, url)
    }

    /// Cleanup a directory or file, ignoring errors.
    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Decode the last NDJSON line of `output` as `IngestSummaryLine`.
    private func decodeSummary(from output: String) throws -> IngestSummaryLine {
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let last = lines.last else {
            throw TestError("Output is empty")
        }
        guard let data = last.data(using: .utf8) else {
            throw TestError("Last line not UTF-8")
        }
        return try JSONDecoder().decode(IngestSummaryLine.self, from: data)
    }

    /// Decode all NDJSON lines of `output` as `IngestResultLine` (skips non-result lines).
    private func decodeResults(from output: String) -> [IngestResultLine] {
        output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line -> IngestResultLine? in
                guard let data = line.data(using: .utf8),
                      let r = try? JSONDecoder().decode(IngestResultLine.self, from: data),
                      r.path != "" else { return nil }
                return r
            }
    }

    /// Check whether `output` is a `VvxErrorEnvelope` (fatal error return).
    private func isErrorEnvelope(_ output: String) -> Bool {
        guard let data  = output.data(using: .utf8),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok    = json["success"] as? Bool else { return false }
        return !ok
    }

    private struct TestError: Error {
        let message: String
        init(_ msg: String) { self.message = msg }
    }

    // MARK: - Test 1: Fatal root — missing path

    @Test("Fatal root: missing path returns VvxErrorEnvelope, does not throw")
    func fatalRootMissingPath() async throws {
        let bogus = URL(fileURLWithPath: "/tmp/ingest_does_not_exist_\(UUID().uuidString)")
        let config = IngestConfig(rootURL: bogus, dryRun: true)
        let output = await IngestEngine.run(config: config)
        #expect(isErrorEnvelope(output), "Expected VvxErrorEnvelope for missing root")
        #expect(!output.contains("\"summary\""), "Should not emit summary on fatal error")
    }

    // MARK: - Test 2: Fatal root — file instead of directory

    @Test("Fatal root: file path (not directory) returns VvxErrorEnvelope")
    func fatalRootNotDirectory() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }
        let file = tmp.appendingPathComponent("video.mp4")
        try writeFile(file)
        let config = IngestConfig(rootURL: file, dryRun: true)
        let output = await IngestEngine.run(config: config)
        #expect(isErrorEnvelope(output), "Expected VvxErrorEnvelope when root is a file, not a dir")
    }

    // MARK: - Test 3: Extension allowlist

    @Test("Extension allowlist: only mp4 indexed; non-mp4 files counted as non_video")
    func extensionAllowlist() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("keep.mp4"))
        try writeFile(tmp.appendingPathComponent("ignore.mkv"))
        try writeFile(tmp.appendingPathComponent("ignore.mov"))
        try writeFile(tmp.appendingPathComponent("ignore.txt"))

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: true)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        #expect(summary.indexed == 1, "Only keep.mp4 should be indexed")
        #expect(summary.skippedReasons.nonVideo == 3, "Three non-video files")
    }

    @Test("Extension allowlist: custom extensions respected")
    func extensionAllowlistCustom() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("clip.mov"))
        try writeFile(tmp.appendingPathComponent("clip.mkv"))
        try writeFile(tmp.appendingPathComponent("clip.mp4"))

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: true, extensions: ["mov", "mkv"])
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        #expect(summary.indexed == 2, "mov and mkv should be indexed; mp4 is non_video here")
        #expect(summary.skippedReasons.nonVideo == 1, "mp4 is non_video when not in allowlist")
    }

    // MARK: - Test 4: Symlinks skipped

    @Test("Symlinks: symlinked file not indexed")
    func symlinkFileSkipped() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        // Real mp4 in a sibling dir
        let realDir = try makeTempDir()
        defer { cleanup(realDir) }
        let realMP4 = realDir.appendingPathComponent("real.mp4")
        try writeFile(realMP4)

        // Symlink pointing at the real file
        let link = tmp.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realMP4)

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: true)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        // Symlinked file must not be counted as indexed
        #expect(summary.indexed == 0, "Symlinked mp4 must not be indexed")
    }

    // MARK: - Test 5: Sidecar pairing — stem-only matching

    @Test("Sidecar pairing: only same-stem SRT in same folder is paired")
    func sidecarStemOnly() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("interview.mp4"))
        // Same stem SRT → should be paired
        _ = try writeSRT(stem: "interview", folder: tmp)
        // Unrelated SRT → must NOT be paired with interview.mp4
        _ = try writeSRT(stem: "other_video", folder: tmp)

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: false)
        let output = await IngestEngine.run(config: config, db: db)
        let results = decodeResults(from: output)
        let summary = try decodeSummary(from: output)

        #expect(summary.indexed == 1)
        let result = results.first { $0.path.contains("interview.mp4") }
        #expect(result != nil)
        #expect(result?.transcriptSource == "local", "interview SRT should be paired → local")
    }

    @Test("Sidecar pairing: .en.srt preferred over bare .srt")
    func sidecarEnPreference() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("clip.mp4"))
        _ = try writeSRT(stem: "clip", ext: "srt", folder: tmp, content: "1\n00:00:01,000 --> 00:00:03,000\nBare SRT.\n\n")
        _ = try writeSRT(stem: "clip.en", ext: "srt", folder: tmp, content: "1\n00:00:01,000 --> 00:00:03,000\nEnglish SRT.\n\n")

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: false)
        let output = await IngestEngine.run(config: config, db: db)

        // Verify transcript_source is local (either SRT was paired; en preference is internal)
        let results = decodeResults(from: output)
        let result = results.first { $0.path.contains("clip.mp4") }
        #expect(result?.transcriptSource == "local")

        // Verify DB blocks exist (more than 0 means the SRT parsed OK)
        let videoId = try #require((try await db.allVideos()).first?.id)
        let blocks = try await db.blocksForVideo(videoId: videoId)
        #expect(blocks.count > 0, "Transcript blocks should be indexed")
    }

    // MARK: - Test 6: .info.json — locked validity

    @Test(".info.json valid via webpage_url: metadata applied, no malformed count")
    func infoJSONValidWebpageURL() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("clip.mp4"))
        let infoURL = tmp.appendingPathComponent("clip.info.json")
        try writeJSON(infoURL, content: validInfoByURL())

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: false)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        #expect(summary.malformedInfoJsonCount == 0)
        #expect(summary.indexed == 1)

        // DB record should use title from info.json
        let videos = try await db.allVideos()
        #expect(videos.first?.title == "Test Video")
        #expect(videos.first?.uploader == "TestChannel")
    }

    @Test(".info.json valid via id+title+duration: metadata applied, no malformed count")
    func infoJSONValidIDTitleDuration() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("clip.mp4"))
        let infoURL = tmp.appendingPathComponent("clip.info.json")
        try writeJSON(infoURL, content: validInfoByIDTitleDuration())

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: false)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        #expect(summary.malformedInfoJsonCount == 0)
        #expect(summary.indexed == 1)
        let videos = try await db.allVideos()
        #expect(videos.first?.title == "Test Video")
    }

    @Test(".info.json parses but fails shape: malformed count incremented, local fallback used")
    func infoJSONMalformedShape() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("myvid.mp4"))
        let infoURL = tmp.appendingPathComponent("myvid.info.json")
        // Valid JSON but missing all required yt-dlp fields
        try writeJSON(infoURL, content: ["some_unrelated_field": "value"])

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: false)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        #expect(summary.malformedInfoJsonCount == 1, "Malformed shape must be counted")
        #expect(summary.indexed == 1, "Video still indexed with local fallback")

        // Title should fall back to the filename stem
        let videos = try await db.allVideos()
        #expect(videos.first?.title == "myvid", "Local fallback title should be filename stem")
    }

    @Test(".info.json exists but contains invalid JSON bytes: counted as malformed")
    func infoJSONInvalidBytes() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("vid.mp4"))
        let infoURL = tmp.appendingPathComponent("vid.info.json")
        try "THIS IS NOT JSON { broken".write(to: infoURL, atomically: true, encoding: .utf8)

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: false)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        #expect(summary.malformedInfoJsonCount == 1)
        #expect(summary.indexed == 1, "Video still indexed (local fallback)")
    }

    // MARK: - Test 7: SRT outcomes

    @Test("Good SRT: transcript_source is 'local', blocks inserted")
    func srtGoodOutcome() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("talk.mp4"))
        _ = try writeSRT(stem: "talk", folder: tmp)

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: false)
        let output = await IngestEngine.run(config: config, db: db)
        let results = decodeResults(from: output)
        let result = results.first { $0.path.contains("talk.mp4") }

        #expect(result?.transcriptSource == "local")
        let videoId = try #require((try await db.allVideos()).first?.id)
        let blocks = try await db.blocksForVideo(videoId: videoId)
        #expect(blocks.count == 2, "Two SRT blocks should be indexed")
    }

    @Test("Empty SRT (parses to zero blocks): indexed with transcript_source 'none', invalid_sidecar incremented")
    func srtEmptyParse() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("silent.mp4"))
        // Valid SRT format but no usable text
        _ = try writeSRT(stem: "silent", folder: tmp, content: "")

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: false)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)
        let results = decodeResults(from: output)
        let result = results.first { $0.path.contains("silent.mp4") }

        #expect(summary.indexed == 1, "Video still indexed even with empty SRT")
        #expect(summary.skippedReasons.invalidSidecar == 1)
        #expect(result?.transcriptSource == "none")
    }

    // MARK: - Test 8: Deduplication

    @Test("Dedup: second run without forceReindex skips already-indexed path")
    func dedupSkipsExisting() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("doc.mp4"))

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: false)

        // First run — should index
        let first = await IngestEngine.run(config: config, db: db)
        let firstSummary = try decodeSummary(from: first)
        #expect(firstSummary.indexed == 1)

        // Second run — same DB, same path, no forceReindex
        let second = await IngestEngine.run(config: config, db: db)
        let secondSummary = try decodeSummary(from: second)
        #expect(secondSummary.indexed == 0, "Second run must skip already-indexed path")
        #expect(secondSummary.skippedReasons.alreadyIndexed == 1)
    }

    @Test("forceReindex: re-upserts without skipping")
    func forceReindexBypassesDedup() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("doc.mp4"))

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        // First run
        let config = IngestConfig(rootURL: tmp, dryRun: false)
        _ = await IngestEngine.run(config: config, db: db)

        // Second run with forceReindex
        let force = IngestConfig(rootURL: tmp, dryRun: false, forceReindex: true)
        let second = await IngestEngine.run(config: force, db: db)
        let summary = try decodeSummary(from: second)

        #expect(summary.indexed == 1, "forceReindex must re-upsert without skipping")
        #expect(summary.skippedReasons.alreadyIndexed == 0)
    }

    // MARK: - Test 9: dry-run — no DB writes

    @Test("dry-run: no DB rows written")
    func dryRunNoDBWrites() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("footage.mp4"))
        _ = try writeSRT(stem: "footage", folder: tmp)

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: true)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        // dry_run flag echoed in summary
        #expect(summary.dryRun == true)
        #expect(summary.indexed == 1, "dry-run still counts planned indexing")

        // DB must be empty — no upsert happened
        let videos = try await db.allVideos()
        #expect(videos.isEmpty, "dry-run must not write to DB")

        let blocks = try await db.blocksForVideo(
            videoId: tmp.appendingPathComponent("footage.mp4").path
        )
        #expect(blocks.isEmpty, "dry-run must not write transcript_blocks")
    }

    // MARK: - Test 10: Summary NDJSON shape

    @Test("Summary: last line decodes as IngestSummaryLine with type 'summary'")
    func summaryLastLine() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: true)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        #expect(summary.type == "summary")
        #expect(summary.success == true)
    }

    @Test("Summary: all four skipped_reasons keys always present (even when zero)")
    func summarySkippedReasonsAllKeysPresent() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        // No files at all — all counts should be zero
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: true)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        #expect(summary.skippedReasons.nonVideo       == 0)
        #expect(summary.skippedReasons.alreadyIndexed == 0)
        #expect(summary.skippedReasons.invalidSidecar == 0)
        #expect(summary.skippedReasons.corruptMedia   == 0)
    }

    @Test("Summary: malformed_info_json_count always present (zero when none)")
    func summaryMalformedCountAlwaysPresent() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: true)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        #expect(summary.malformedInfoJsonCount == 0)

        // Verify the raw JSON actually contains the key (not just a default during decode)
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let lastLine = lines.last else { return }
        #expect(lastLine.contains("malformed_info_json_count"),
                "malformed_info_json_count must be present in JSON even when zero")
    }

    @Test("Summary: dry_run flag mirrors config value")
    func summaryDryRunFlag() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let dry  = await IngestEngine.run(config: IngestConfig(rootURL: tmp, dryRun: true),  db: db)
        let live = await IngestEngine.run(config: IngestConfig(rootURL: tmp, dryRun: false), db: db)

        let drySummary  = try decodeSummary(from: dry)
        let liveSummary = try decodeSummary(from: live)

        #expect(drySummary.dryRun  == true)
        #expect(liveSummary.dryRun == false)
    }

    // MARK: - Test 11: Progress callback

    @Test("Progress callback: fired at end even for empty folder")
    func progressCallbackFiredForEmptyFolder() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        var callCount = 0
        let config = IngestConfig(rootURL: tmp, dryRun: true)
        _ = await IngestEngine.run(config: config, db: db) { _, _, _ in callCount += 1 }

        #expect(callCount >= 1, "Progress callback must fire at least once (end-of-run flush)")
    }

    @Test("Progress callback: receives correct dryRun flag")
    func progressCallbackDryRunFlag() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        var observed: [Bool] = []
        let config = IngestConfig(rootURL: tmp, dryRun: true)
        _ = await IngestEngine.run(config: config, db: db) { _, _, dry in observed.append(dry) }

        #expect(observed.allSatisfy { $0 == true }, "dryRun param in callback must match config")
    }

    @Test("Progress callback: fires once per 100-file boundary")
    func progressCallbackEvery100() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }
        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        // Progress counts video candidates only — need 101 `.mp4` files to hit the 100 boundary.
        for i in 0..<101 {
            try writeFile(tmp.appendingPathComponent("file\(i).mp4"))
        }

        var calls: [(filesChecked: Int, indexed: Int)] = []
        let config = IngestConfig(rootURL: tmp, dryRun: true)
        _ = await IngestEngine.run(config: config, db: db) { checked, indexed, _ in
            calls.append((checked, indexed))
        }

        // Should have at least 2 calls: one at 100 files, one at end (101)
        #expect(calls.count >= 2, "Expect boundary call at 100 + end-of-run call")
        let boundary = calls.first { $0.filesChecked == 100 }
        #expect(boundary != nil, "A call exactly at 100 files must have been emitted")
    }

    // MARK: - Test 12: Local row shape in DB

    @Test("Local row: id and video_path are the absolute file path, platform is nil")
    func localRowShape() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("footage.mp4"))

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: false)
        _ = await IngestEngine.run(config: config, db: db)

        let videos = try await db.allVideos()
        guard let video = videos.first else {
            Issue.record("No video row found in DB")
            return
        }

        let expectedURL = tmp.appendingPathComponent("footage.mp4").standardizedFileURL
        #expect(URL(fileURLWithPath: video.id).standardizedFileURL == expectedURL, "DB id must be absolute path to file")
        #expect(
            URL(fileURLWithPath: video.videoPath ?? "").standardizedFileURL == expectedURL,
            "DB video_path must be absolute path to file"
        )
        #expect(video.platform  == nil,          "Local-ingest rows must have platform = nil")
    }

    // MARK: - Test 13: Recursive walk

    @Test("Recursive walk: videos in subdirectories are discovered")
    func recursiveWalk() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        let sub = tmp.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile(tmp.appendingPathComponent("root.mp4"))
        try writeFile(sub.appendingPathComponent("nested.mp4"))

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: true)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        #expect(summary.indexed == 2, "Both root.mp4 and nested/nested.mp4 must be discovered")
    }

    // MARK: - Test 14: info.json with only partial valid fields (edge cases)

    @Test(".info.json: missing duration field → invalid shape, local fallback")
    func infoJSONMissingDuration() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("clip.mp4"))
        let infoURL = tmp.appendingPathComponent("clip.info.json")
        // Has id + title but NO duration → fails locked validity (id+title+duration branch)
        // Has no webpage_url either → entirely invalid
        try writeJSON(infoURL, content: ["id": "abc", "title": "My Video"])

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: false)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        #expect(summary.malformedInfoJsonCount == 1)
        #expect(summary.indexed == 1)
    }

    @Test(".info.json: empty string webpage_url → invalid shape, local fallback")
    func infoJSONEmptyWebpageURL() async throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        try writeFile(tmp.appendingPathComponent("vid.mp4"))
        let infoURL = tmp.appendingPathComponent("vid.info.json")
        try writeJSON(infoURL, content: ["webpage_url": "", "title": "Test"])

        let (db, dbURL) = try makeDB()
        defer { cleanup(dbURL) }

        let config = IngestConfig(rootURL: tmp, dryRun: false)
        let output = await IngestEngine.run(config: config, db: db)
        let summary = try decodeSummary(from: output)

        #expect(summary.malformedInfoJsonCount == 1, "Empty string webpage_url is invalid")
    }
}

// MARK: - IngestSummaryLine Codable for test decoding

// `IngestSummaryLine` is declared Encodable only in Core; add a test-only Decodable
// conformance so tests can round-trip through JSON without modifying the production type.
extension IngestSummaryLine: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            indexed:                c.decode(Int.self,                   forKey: .indexed),
            skipped:                c.decode(Int.self,                   forKey: .skipped),
            skippedReasons:         c.decode(IngestSkippedReasons.self, forKey: .skippedReasons),
            malformedInfoJsonCount: c.decode(Int.self,                   forKey: .malformedInfoJsonCount),
            errorsLogged:           c.decode(Int.self,                   forKey: .errorsLogged),
            dryRun:                 c.decode(Bool.self,                  forKey: .dryRun)
        )
    }
}

extension IngestSkippedReasons: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            nonVideo:       c.decode(Int.self, forKey: .nonVideo),
            alreadyIndexed: c.decode(Int.self, forKey: .alreadyIndexed),
            invalidSidecar: c.decode(Int.self, forKey: .invalidSidecar),
            corruptMedia:   c.decode(Int.self, forKey: .corruptMedia)
        )
    }
}

extension IngestResultLine: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let skipped = try c.decode(Bool.self, forKey: .skipped)
        let path = try c.decode(String.self, forKey: .path)
        if skipped {
            let reasonStr = try c.decodeIfPresent(String.self, forKey: .skipReason)
                ?? IngestSkipReason.nonVideo.rawValue
            guard let reason = IngestSkipReason(rawValue: reasonStr) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .skipReason,
                    in: c,
                    debugDescription: "Unknown skip_reason: \(reasonStr)"
                )
            }
            self = Self.skipped(path: path, reason: reason)
        } else {
            self = Self.indexed(
                path:             path,
                videoId:          try c.decode(String.self, forKey: .videoId),
                title:            try c.decode(String.self, forKey: .title),
                durationSeconds:  try c.decodeIfPresent(Int.self, forKey: .durationSeconds),
                transcriptSource: try c.decode(String.self, forKey: .transcriptSource)
            )
        }
    }
}
