import Foundation

// MARK: - Manifest models

public struct GatherManifestEngagement: Encodable, Sendable {
    public let viewCount:    Int?
    public let likeCount:    Int?
    public let commentCount: Int?

    public init(viewCount: Int?, likeCount: Int?, commentCount: Int?) {
        self.viewCount    = viewCount
        self.likeCount    = likeCount
        self.commentCount = commentCount
    }
}

public struct GatherManifestChapter: Encodable, Sendable {
    public let title: String
    public let index: Int

    public init(title: String, index: Int) {
        self.title = title
        self.index = index
    }
}

public struct GatherManifestClip: Encodable, Sendable {
    public let id:                   String
    public let videoId:              String
    public let sourceUrl:            String
    public let title:                String
    public let uploader:             String?
    /// Relative path to MP4 from the manifest's directory (e.g. `"./01_Lex_01-14-32.mp4"`).
    public let mp4Path:              String
    /// Relative path to SRT, or `null` when no transcript exists.
    public let srtPath:              String?
    /// `"none"` when no transcript was available; `"local"` when blocks came from the archive.
    public let transcriptSource:     String?
    /// Logical clip start before pad is applied (L0).
    public let logicalStartSeconds:  Double
    /// Logical clip end before pad is applied (L1).
    public let logicalEndSeconds:    Double
    public let padSeconds:           Double
    /// Actual start fed to ffmpeg: `max(0, L0 - pad)`.
    public let paddedStartSeconds:   Double
    /// Actual end fed to ffmpeg: `L1 + pad` (clamped to duration when known).
    public let paddedEndSeconds:     Double
    public let engagement:           GatherManifestEngagement?
    public let chapter:              GatherManifestChapter?
    /// Literal shell command to reproduce this exact clip with the same pad (and Step 5 flags).
    public let reproduceCommand:     String
    /// `true` only if the whole-cue rule had to be overridden (currently always `false`).
    public let srtCuesTrimmed:       Bool
    // MARK: Step 5 fields
    /// Relative path to the JPEG thumbnail extracted at logical start (L0), or `null`.
    public let thumbnailPath:        String?
    /// `true` when `--embed-source` was on and the clip mux succeeded.
    public let embedSourceApplied:   Bool
    /// Populated when embed was skipped or partially applied — otherwise `null`.
    public let embedSourceNote:      String?
    /// Encode mode used: `"copy"` (--fast), `"default"`, or `"exact"` (--exact, libx264 CRF 18).
    public let encodeMode:           String

    public init(
        id: String, videoId: String, sourceUrl: String, title: String,
        uploader: String?, mp4Path: String, srtPath: String?,
        transcriptSource: String?, logicalStartSeconds: Double,
        logicalEndSeconds: Double, padSeconds: Double,
        paddedStartSeconds: Double, paddedEndSeconds: Double,
        engagement: GatherManifestEngagement?, chapter: GatherManifestChapter?,
        reproduceCommand: String, srtCuesTrimmed: Bool, thumbnailPath: String?,
        embedSourceApplied: Bool, embedSourceNote: String?, encodeMode: String
    ) {
        self.id                  = id
        self.videoId             = videoId
        self.sourceUrl           = sourceUrl
        self.title               = title
        self.uploader            = uploader
        self.mp4Path             = mp4Path
        self.srtPath             = srtPath
        self.transcriptSource    = transcriptSource
        self.logicalStartSeconds = logicalStartSeconds
        self.logicalEndSeconds   = logicalEndSeconds
        self.padSeconds          = padSeconds
        self.paddedStartSeconds  = paddedStartSeconds
        self.paddedEndSeconds    = paddedEndSeconds
        self.engagement          = engagement
        self.chapter             = chapter
        self.reproduceCommand    = reproduceCommand
        self.srtCuesTrimmed      = srtCuesTrimmed
        self.thumbnailPath       = thumbnailPath
        self.embedSourceApplied  = embedSourceApplied
        self.embedSourceNote     = embedSourceNote
        self.encodeMode          = encodeMode
    }
}

public struct GatherManifest: Encodable, Sendable {
    public let schemaVersion:      Int
    public let query:              String
    public let padSeconds:         Double
    public let generatedAt:        String
    /// `true` when the run used `--thumbnails`.
    public let thumbnailsEnabled:  Bool
    /// `true` when the run used `--embed-source`.
    public let embedSourceEnabled: Bool
    /// Encode mode for this run: `"copy"` (--fast), `"default"`, or `"exact"` (--exact).
    public let encodeMode:         String
    public let clips:              [GatherManifestClip]

    public init(
        query: String, padSeconds: Double, generatedAt: String,
        thumbnailsEnabled: Bool, embedSourceEnabled: Bool,
        encodeMode: String, clips: [GatherManifestClip]
    ) {
        self.schemaVersion      = 2
        self.query              = query
        self.padSeconds         = padSeconds
        self.generatedAt        = generatedAt
        self.thumbnailsEnabled  = thumbnailsEnabled
        self.embedSourceEnabled = embedSourceEnabled
        self.encodeMode         = encodeMode
        self.clips              = clips
    }
}

// MARK: - Writer

public enum GatherSidecarWriter {

    /// Write `manifest.json` and `clips.md` into `outputDir`.
    ///
    /// Both writes are non-atomic best-effort — failures are non-fatal for the
    /// gather run (caller should surface them as warnings, not hard errors).
    public static func write(
        clips:              [GatherManifestClip],
        query:              String,
        padSeconds:         Double,
        outputDir:          String,
        thumbnailsEnabled:  Bool,
        embedSourceEnabled: Bool,
        encodeMode:         String
    ) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let manifest = GatherManifest(
            query:              query,
            padSeconds:         padSeconds,
            generatedAt:        iso.string(from: Date()),
            thumbnailsEnabled:  thumbnailsEnabled,
            embedSourceEnabled: embedSourceEnabled,
            encodeMode:         encodeMode,
            clips:              clips
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        let manifestPath = (outputDir as NSString).appendingPathComponent("manifest.json")
        try manifestData.write(to: URL(fileURLWithPath: manifestPath))

        let md = buildClipsMD(clips: clips, query: query)
        let mdPath = (outputDir as NSString).appendingPathComponent("clips.md")
        try md.write(toFile: mdPath, atomically: true, encoding: .utf8)
    }

    // MARK: - clips.md template

    private static func buildClipsMD(clips: [GatherManifestClip], query: String) -> String {
        let dateStr: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        var lines: [String] = [
            "# Gather: \"\(query)\"",
            "*Generated by vvx on \(dateStr)*",
            ""
        ]

        for clip in clips {
            lines.append("## \(clip.id). \(clip.title)")
            lines.append("* **Source:** \(clip.sourceUrl)")

            let startFmt = TimeParser.formatHHMMSS(clip.logicalStartSeconds)
            let endFmt   = TimeParser.formatHHMMSS(clip.logicalEndSeconds)
            lines.append("* **Clip time (logical):** \(startFmt) – \(endFmt)")

            if let eng = clip.engagement {
                var parts: [String] = []
                if let v = eng.viewCount    { parts.append(formatCount(v) + " views") }
                if let l = eng.likeCount    { parts.append(formatCount(l) + " likes") }
                if let c = eng.commentCount { parts.append(formatCount(c) + " comments") }
                if !parts.isEmpty { lines.append("* **Engagement:** " + parts.joined(separator: " | ")) }
            }

            if clip.srtPath == nil {
                lines.append("* **Subtitles:** No transcript — SRT file omitted")
            }

            lines.append("* **Reproduce:** `\(clip.reproduceCommand)`")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
