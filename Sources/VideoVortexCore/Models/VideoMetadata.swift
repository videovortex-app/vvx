import Foundation

/// Structured output produced by VideoVortexCore after a completed download.
///
/// This is the core data contract — the "clean video data" that LLM agents consume.
/// Serializes to JSON via `--json` in the CLI, and is returned by the `/ingest` + `/library`
/// endpoints in the Local Agent API.
///
/// Analogous to what Firecrawl returns for a web page: structured, normalized,
/// ready for LLM context without any further processing.
public struct VideoMetadata: Codable, Sendable, Identifiable {

    public var id: UUID

    /// The original URL that was downloaded.
    public var url: String

    /// Cleaned display title (sanitized via VideoTitleSanitizer).
    public var title: String

    /// Human-readable platform (YouTube, TikTok, X, etc.).
    public var platform: String?

    /// Video resolution string (e.g. "1920x1080"), nil for audio-only formats.
    public var resolution: String?

    /// Playback duration in seconds.
    public var durationSeconds: Int?

    /// File size of the primary media file in bytes.
    public var fileSize: Int64

    /// Absolute path to the primary media file (.mp4 or .mp3).
    public var outputPath: String

    /// Absolute paths to any .srt subtitle files (archive mode only).
    public var subtitlePaths: [String]

    /// Absolute path to the cached JPEG thumbnail preview.
    public var thumbnailPath: String?

    /// Absolute path to the .description sidecar (archive mode only).
    public var descriptionPath: String?

    /// Absolute path to the .info.json sidecar (archive mode only).
    public var infoJSONPath: String?

    /// Like count at download time (nil if the platform did not expose it).
    public var likeCount: Int?

    /// Comment count at download time (nil if the platform did not expose it).
    public var commentCount: Int?

    /// The download format used.
    public var format: DownloadFormat

    /// Whether the file lives under the Archive root (with per-video folder + sidecars).
    public var isArchiveMode: Bool

    /// When the download completed.
    public var completedAt: Date

    public init(
        id: UUID = UUID(),
        url: String,
        title: String,
        platform: String? = nil,
        resolution: String? = nil,
        durationSeconds: Int? = nil,
        fileSize: Int64 = 0,
        outputPath: String,
        subtitlePaths: [String] = [],
        thumbnailPath: String? = nil,
        descriptionPath: String? = nil,
        infoJSONPath: String? = nil,
        likeCount: Int? = nil,
        commentCount: Int? = nil,
        format: DownloadFormat,
        isArchiveMode: Bool,
        completedAt: Date = .now
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.platform = platform
        self.resolution = resolution
        self.durationSeconds = durationSeconds
        self.fileSize = fileSize
        self.outputPath = outputPath
        self.subtitlePaths = subtitlePaths
        self.thumbnailPath = thumbnailPath
        self.descriptionPath = descriptionPath
        self.infoJSONPath = infoJSONPath
        self.likeCount    = likeCount
        self.commentCount = commentCount
        self.format = format
        self.isArchiveMode = isArchiveMode
        self.completedAt = completedAt
    }
}

// MARK: - JSON encoding helpers for CLI output

extension VideoMetadata {
    /// Returns a pretty-printed JSON string for CLI --json output.
    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
