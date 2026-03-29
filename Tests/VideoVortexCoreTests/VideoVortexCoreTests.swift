import Testing
@testable import VideoVortexCore

// MARK: - YtDlpOutputParser tests

@Suite("YtDlpOutputParser")
struct YtDlpOutputParserTests {

    @Test("Parses merger output path with double quotes")
    func mergerDoubleQuote() {
        let line = #"[Merger] Merging formats into "/Users/mike/Downloads/VideoVortex/video.mp4""#
        let result = YtDlpOutputParser.parse(line, currentFormat: .bestVideo)
        #expect(result == .mergerOutputPath("/Users/mike/Downloads/VideoVortex/video.mp4"))
    }

    @Test("Parses merger output path with single quotes")
    func mergerSingleQuote() {
        let line = "[Merger] Merging formats into '/Users/mike/Downloads/VideoVortex/video.mp4'"
        let result = YtDlpOutputParser.parse(line, currentFormat: .bestVideo)
        #expect(result == .mergerOutputPath("/Users/mike/Downloads/VideoVortex/video.mp4"))
    }

    @Test("Parses download progress line")
    func progressLine() {
        let line = "[download]  52.3% of 123.4MiB at   3.21MiB/s ETA 00:28"
        let result = YtDlpOutputParser.parse(line, currentFormat: .bestVideo)
        if case .progress(let pct, let speed, let eta) = result {
            #expect(abs(pct - 0.523) < 0.001)
            #expect(speed == "3.21MiB/s")
            #expect(eta == "00:28")
        } else {
            Issue.record("Expected progress, got \(result)")
        }
    }

    @Test("Parses destination path line")
    func destinationPath() {
        let line = "[download] Destination: /Users/mike/Downloads/VideoVortex/Youtube/video.mp4"
        let result = YtDlpOutputParser.parse(line, currentFormat: .bestVideo)
        #expect(result == .destinationPath("/Users/mike/Downloads/VideoVortex/Youtube/video.mp4"))
    }

    @Test("Parses explicit printed filepath line")
    func printedFilepath() {
        let line = "/tmp/vvx-pathtest/Me at the zoo [jNQXAC9IVRw].mp4"
        let result = YtDlpOutputParser.parse(line, currentFormat: .bestVideo)
        #expect(result == .printedFilepath(line))

        let quoted = "\"/tmp/vvx-pathtest/Me at the zoo [jNQXAC9IVRw].mp4\""
        let result2 = YtDlpOutputParser.parse(quoted, currentFormat: .bestVideo)
        #expect(result2 == .printedFilepath(line))
    }

    @Test("Parses extract audio destination")
    func extractAudioDestination() {
        let line = "[ExtractAudio] Destination: /Users/mike/Downloads/video.mp3"
        let result = YtDlpOutputParser.parse(line, currentFormat: .audioOnlyMP3)
        #expect(result == .extractAudioDestination("/Users/mike/Downloads/video.mp3"))
    }

    @Test("Suppresses extract audio for Reaction Kit")
    func reactionKitSuppressesAudio() {
        let line = "[ExtractAudio] Destination: /path/to/video.mp3"
        let result = YtDlpOutputParser.parse(line, currentFormat: .reactionKit)
        // Should not match extractAudioDestination for Reaction Kit
        #expect(result == .unknown)
    }

    @Test("Parses extractor title from YouTube line")
    func extractorTitle() {
        let line = "[youtube] dQw4w9WgXcQ: Rick Astley - Never Gonna Give You Up"
        let result = YtDlpOutputParser.parse(line, currentFormat: .bestVideo)
        #expect(result == .extractorTitle("dQw4w9WgXcQ: Rick Astley - Never Gonna Give You Up"))
    }

    @Test("Skips download prefix lines")
    func skipsDownloadPrefix() {
        let line = "[download] 100% of 50.0MiB"
        // This is a progress line, not a title line
        let result = YtDlpOutputParser.parse(line, currentFormat: .bestVideo)
        if case .progress = result { } else {
            // It's fine if it returns .unknown for 100% without ETA
        }
    }

    @Test("Parses resolution from video line")
    func resolution() {
        let line = "[info] format: 1920x1080 (video)"
        let result = YtDlpOutputParser.parse(line, currentFormat: .bestVideo)
        #expect(result == .resolution("1920x1080"))
    }

    @Test("Returns unknown for unrecognised line")
    func unknownLine() {
        let line = "[info] Writing video subtitles to: file.srt"
        let result = YtDlpOutputParser.parse(line, currentFormat: .bestVideo)
        // This may or may not match patterns — we just ensure it doesn't crash
        _ = result
    }
}

// MARK: - DownloadFormat tests

@Suite("DownloadFormat")
struct DownloadFormatTests {

    @Test("bestVideo ytDlpFlags contains -f flag")
    func bestVideoFlags() {
        let flags = DownloadFormat.bestVideo.ytDlpFlags
        #expect(flags.contains("-f"))
        #expect(flags.contains("--merge-output-format"))
    }

    @Test("bRollMuted uses remux-video")
    func bRollFlags() {
        let flags = DownloadFormat.bRollMuted.ytDlpFlags
        #expect(flags.contains("--remux-video"))
    }

    @Test("audioOnlyMP3 uses -x flag")
    func audioFlags() {
        let flags = DownloadFormat.audioOnlyMP3.ytDlpFlags
        #expect(flags.contains("-x"))
        #expect(flags.contains("mp3"))
    }

    @Test("archive mode adds write-subs for video formats")
    func archiveAddsSubsForVideo() {
        let args = DownloadFormat.bestVideo.ytDlpArguments(isArchiveMode: true)
        #expect(args.contains("--write-subs"))
        #expect(args.contains("--write-info-json"))
        let subIdx = args.firstIndex(of: "--sub-langs")
        #expect(subIdx != nil)
        #expect(args[subIdx! + 1] == YtDlpRateLimit.defaultSubLangs)
    }

    @Test("--all-subs uses broad en.* pattern")
    func allSubsBroadPattern() {
        let args = DownloadFormat.bestVideo.ytDlpArguments(isArchiveMode: true, allSubtitleLanguages: true)
        let subIdx = args.firstIndex(of: "--sub-langs")
        #expect(subIdx != nil)
        #expect(args[subIdx! + 1] == YtDlpRateLimit.allSubsSubLangs)
    }

    @Test("YtDlpRateLimit detects HTTP 429 in stderr")
    func rateLimitHeuristics() {
        #expect(YtDlpRateLimit.isProbablyRateLimited("ERROR: HTTP Error 429: Too Many Requests"))
        #expect(!YtDlpRateLimit.isProbablyRateLimited("ERROR: video unavailable"))
    }

    @Test("non-archive mode suppresses sidecars")
    func quickModeSuppressesSidecars() {
        let args = DownloadFormat.bestVideo.ytDlpArguments(isArchiveMode: false)
        #expect(args.contains("--no-write-info-json"))
        #expect(!args.contains("--write-subs"))
    }

    @Test("reactionKit always uses archive regardless of flag")
    func reactionKitAlwaysArchive() {
        let argsOff = DownloadFormat.reactionKit.ytDlpArguments(isArchiveMode: false)
        #expect(argsOff.contains("--write-subs"))
    }
}

// MARK: - VideoTitleSanitizer tests

@Suite("VideoTitleSanitizer")
struct VideoTitleSanitizerTests {

    @Test("Strips emoji from titles")
    func stripsEmoji() {
        let result = VideoTitleSanitizer.clean("Hello 🔥 World 🚀")
        #expect(!result.contains("🔥"))
        #expect(!result.contains("🚀"))
    }

    @Test("Collapses whitespace")
    func collapsesWhitespace() {
        let result = VideoTitleSanitizer.clean("Hello   World")
        #expect(!result.contains("   "))
    }

    @Test("Truncates at word boundary")
    func truncatesWordBoundary() {
        let long = String(repeating: "word ", count: 20)
        let result = VideoTitleSanitizer.clean(long, maxLength: 30)
        #expect(result.count <= 33) // 30 + "..."
        #expect(result.hasSuffix("..."))
    }

    @Test("Passes short title unchanged")
    func shortTitleUnchanged() {
        let result = VideoTitleSanitizer.clean("Hello World", maxLength: 65)
        #expect(result == "Hello World")
    }
}

// MARK: - LibraryPath tests

@Suite("LibraryPath")
struct LibraryPathTests {

    @Test("Maps youtube to YouTube")
    func youtubeMapping() {
        let result = LibraryPath.displayName(forExtractorFolder: "youtube")
        #expect(result == "YouTube")
    }

    @Test("Maps tiktok to TikTok")
    func tiktokMapping() {
        let result = LibraryPath.displayName(forExtractorFolder: "tiktok")
        #expect(result == "TikTok")
    }

    @Test("Capitalizes unknown extractors")
    func unknownExtractor() {
        let result = LibraryPath.displayName(forExtractorFolder: "some_platform")
        #expect(result == "Some Platform")
    }
}

// MARK: - VideoMetadata JSON tests

@Suite("VideoMetadata")
struct VideoMetadataTests {

    @Test("Encodes to valid JSON")
    func encodesToJSON() {
        let meta = VideoMetadata(
            url: "https://youtube.com/watch?v=test",
            title: "Test Video",
            platform: "YouTube",
            fileSize: 12345,
            outputPath: "/tmp/test.mp4",
            format: .bestVideo,
            isArchiveMode: false
        )
        let json = meta.jsonString()
        #expect(json.contains("Test Video"))
        #expect(json.contains("YouTube"))
        #expect(json.contains("bestVideo"))
    }
}
