import Foundation

/// Configuration handed to `VideoDownloader` to start a download job.
/// Contains everything the downloader needs — no UserDefaults reads inside the engine.
public struct DownloadJobConfig: Sendable {

    /// The video URL to download.
    public let url: String

    /// The yt-dlp format profile to use.
    public let format: DownloadFormat

    /// Whether to use archive mode (per-video folder + .srt/.info.json sidecars).
    public let isArchiveMode: Bool

    /// The directory where yt-dlp will write output files.
    public let outputDirectory: URL

    /// Path to the yt-dlp binary.
    public let ytDlpPath: URL

    /// Path to the ffmpeg binary (nil = yt-dlp will use its own ffmpeg search path).
    public let ffmpegPath: URL?

    /// Browser to extract cookies from (e.g. "safari", "chrome", "firefox").
    /// Allows vvx to access age-restricted, private, and login-gated content by
    /// borrowing the user's active browser session. Requires Full Disk Access on macOS
    /// for browsers other than Safari.
    /// Maps to yt-dlp's `--cookies-from-browser <name>` flag.
    public let browserCookies: String?

    /// When true, strips SponsorBlock "sponsor" segments from both the downloaded
    /// media and the generated .srt transcript before returning results.
    /// Keeps LLM context windows free of paid promotions.
    /// Maps to yt-dlp's `--sponsorblock-remove sponsor` flag (requires ffmpeg).
    public let removeSponsorSegments: Bool

    /// When true, use `--sub-langs en.*` instead of the safer default (`en,en-orig`).
    public let allSubtitleLanguages: Bool

    /// When true, append yt-dlp `--sleep-requests` / `--sleep-interval` for gentler pacing.
    /// Used for multi-URL fetch to reduce burst traffic.
    public let requestHumanLikePacing: Bool

    /// When true (default), a successful download is indexed into `vortex.db` in the background.
    /// Set to false for standalone downloads that must not touch the database (e.g. `vvx dl`).
    public let indexInDatabase: Bool

    /// When true, write the video as a single file in `outputDirectory` (yt-dlp `%(title).100B.%(ext)s`).
    /// When false (default), use the structured quick or archive path template.
    public let useFlatOutputTemplate: Bool

    public init(
        url: String,
        format: DownloadFormat,
        isArchiveMode: Bool,
        outputDirectory: URL,
        ytDlpPath: URL,
        ffmpegPath: URL? = nil,
        browserCookies: String? = nil,
        removeSponsorSegments: Bool = false,
        allSubtitleLanguages: Bool = false,
        requestHumanLikePacing: Bool = false,
        indexInDatabase: Bool = true,
        useFlatOutputTemplate: Bool = false
    ) {
        self.url               = url
        self.format            = format
        self.isArchiveMode     = isArchiveMode
        self.outputDirectory   = outputDirectory
        self.ytDlpPath         = ytDlpPath
        self.ffmpegPath        = ffmpegPath
        self.browserCookies    = browserCookies
        self.removeSponsorSegments = removeSponsorSegments
        self.allSubtitleLanguages = allSubtitleLanguages
        self.requestHumanLikePacing = requestHumanLikePacing
        self.indexInDatabase   = indexInDatabase
        self.useFlatOutputTemplate = useFlatOutputTemplate
    }
}
