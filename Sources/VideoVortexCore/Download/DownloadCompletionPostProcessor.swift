import Foundation

#if os(macOS)
import AVFoundation
#endif

/// Rename, Spotlight comment, thumbnail, and metadata extraction after yt-dlp finishes.
/// Runs off the main thread. Returns a fully-populated `VideoMetadata` on success.
public enum DownloadCompletionPostProcessor {

    public enum PostProcessError: Error, LocalizedError {
        case outputMissing
        public var errorDescription: String? { "Output file not found after download." }
    }

    /// Process the completed download:
    /// 1. Rename file to clean title stem
    /// 2. Write Spotlight/Finder comment via xattr (macOS only, no-op on Linux)
    /// 3. Extract thumbnail JPEG to cache directory
    /// 4. Collect sidecar paths (.srt, .description, .info.json) if archive mode
    /// 5. Probe duration via AVFoundation (macOS) or ffprobe (Linux)
    /// 6. Return VideoMetadata
    public static func process(
        resolvedPath: String,
        rawExtractorTitle: String?,
        outputDirectory: URL,
        taskId: UUID,
        downloadFormat: DownloadFormat,
        originalURL: String,
        thumbnailCacheDirectory: URL
    ) async throws -> VideoMetadata {
        var fileURL = URL(fileURLWithPath: resolvedPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PostProcessError.outputMissing
        }

        // Platform from extractor folder
        let platform = LibraryPath.platformDisplayName(libraryRoot: outputDirectory, fileURL: fileURL)

        // Clean title and rename
        let rawTitle    = rawExtractorTitle ?? fileURL.deletingPathExtension().lastPathComponent
        let cleanedStem = VideoTitleSanitizer.clean(rawTitle, maxLength: 65)
        let ext         = fileURL.pathExtension.isEmpty ? "mp4" : fileURL.pathExtension
        let parent      = fileURL.deletingLastPathComponent()
        let destURL = uniqueDestinationURL(
            movingFrom: fileURL,
            in: parent,
            stem: cleanedStem.isEmpty ? "Video" : cleanedStem,
            extension: ext
        )
        if fileURL.standardizedFileURL.path != destURL.standardizedFileURL.path {
            try FileManager.default.moveItem(at: fileURL, to: destURL)
            fileURL = destURL
        }

        VideoTitleSanitizer.writeFinderCommentViaXattr(to: fileURL, comment: rawTitle)

        // Thumbnail cache
        let thumbPath: String?
        if downloadFormat == .audioOnlyMP3 {
            thumbPath = nil
        } else {
            thumbPath = try? writeThumbnailCache(for: fileURL, taskId: taskId, cacheDir: thumbnailCacheDirectory)
        }

        // File size
        let sizeVal  = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = Int64(sizeVal.fileSize ?? 0)

        // Duration
        let durationSeconds = await durationSecondsFromMediaFile(at: fileURL)

        // Display title
        let displayTitle = fileURL.deletingPathExtension().lastPathComponent

        // Archive sidecars (.srt, .description, .info.json)
        let isArchive = fileURL.path.contains(MediaStoragePaths.archiveFolderName)
        let (subtitlePaths, descriptionPath, infoJSONPath) = collectSidecars(near: fileURL, isArchive: isArchive)

        // Engagement counts from the .info.json sidecar written by yt-dlp --archive.
        // Falls back to nil silently if the file is absent (non-archive / audio-only).
        let (likeCount, commentCount) = readEngagementCounts(from: infoJSONPath)

        return VideoMetadata(
            url: originalURL,
            title: displayTitle,
            platform: platform,
            resolution: nil,   // resolution is set by caller from parser output
            durationSeconds: durationSeconds,
            fileSize: fileSize,
            outputPath: fileURL.path,
            subtitlePaths: subtitlePaths,
            thumbnailPath: thumbPath,
            descriptionPath: descriptionPath,
            infoJSONPath: infoJSONPath,
            likeCount: likeCount,
            commentCount: commentCount,
            format: downloadFormat,
            isArchiveMode: isArchive
        )
    }

    // MARK: - Sidecar discovery

    private static func collectSidecars(
        near fileURL: URL,
        isArchive: Bool
    ) -> (subtitlePaths: [String], descriptionPath: String?, infoJSONPath: String?) {
        guard isArchive else { return ([], nil, nil) }

        let folder = fileURL.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ) else { return ([], nil, nil) }

        var srtPaths: [String] = []
        var descPath: String?
        var infoPath: String?

        for item in contents {
            let ext = item.pathExtension.lowercased()
            if ext == "srt" || ext == "vtt" {
                srtPaths.append(item.path)
            } else if ext == "description" || item.lastPathComponent.hasSuffix(".description") {
                descPath = item.path
            } else if item.lastPathComponent.hasSuffix(".info.json") {
                infoPath = item.path
            }
        }

        return (srtPaths.sorted(), descPath, infoPath)
    }

    // MARK: - Helpers

    private static func uniqueDestinationURL(
        movingFrom source: URL,
        in directory: URL,
        stem: String,
        extension ext: String
    ) -> URL {
        let safeStem = stem.isEmpty ? "Video" : stem
        var candidate = directory.appendingPathComponent("\(safeStem).\(ext)")
        if source.standardizedFileURL == candidate.standardizedFileURL { return candidate }
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safeStem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private static func writeThumbnailCache(for videoURL: URL, taskId: UUID, cacheDir: URL) throws -> String {
        let out = cacheDir.appendingPathComponent("\(taskId.uuidString).jpg", isDirectory: false)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try VideoThumbnailGenerator.writeJPEGPreview(from: videoURL, to: out)
        return out.path
    }

    // MARK: - Duration probing (platform-specific)

    private static func durationSecondsFromMediaFile(at fileURL: URL) async -> Int? {
#if os(macOS)
        let asset = AVURLAsset(url: fileURL)
        guard let dur = try? await asset.load(.duration) else { return nil }
        guard dur.isValid, !dur.isIndefinite else { return nil }
        let sec = CMTimeGetSeconds(dur)
        guard sec.isFinite, sec > 0 else { return nil }
        return Int(sec.rounded())
#else
        return durationSecondsViaFFprobe(at: fileURL)
#endif
    }

    /// Probes duration using:
    ///   ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 <file>
    /// Outputs only the raw decimal duration string (e.g. "145.32"). No JSON parsing needed.
    private static func durationSecondsViaFFprobe(at fileURL: URL) -> Int? {
        guard let ffprobeURL = resolveFFprobe() else { return nil }

        let proc = Process()
        proc.executableURL = ffprobeURL
        proc.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            fileURL.path
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = FileHandle.nullDevice

        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let raw = output, let seconds = Double(raw), seconds > 0 else { return nil }
        return Int(seconds.rounded())
    }

    private static func resolveFFprobe() -> URL? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: "\(dir)/ffprobe")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Engagement extraction from .info.json

    /// Reads `like_count` and `comment_count` from the yt-dlp `.info.json` sidecar.
    ///
    /// Returns `(nil, nil)` if the file is absent, unreadable, or missing those keys —
    /// so non-archive / audio-only downloads degrade gracefully rather than failing.
    private static func readEngagementCounts(
        from infoJSONPath: String?
    ) -> (likeCount: Int?, commentCount: Int?) {
        guard let path = infoJSONPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return (nil, nil)
        }
        struct EngagementInfo: Decodable {
            let like_count:    Int?
            let comment_count: Int?
        }
        guard let info = try? JSONDecoder().decode(EngagementInfo.self, from: data) else {
            return (nil, nil)
        }
        return (info.like_count, info.comment_count)
    }
}
