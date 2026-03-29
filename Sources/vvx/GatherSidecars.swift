import Foundation
import VideoVortexCore

// MARK: - Manifest models

struct GatherManifestEngagement: Encodable {
    let viewCount: Int?
    let likeCount: Int?
    let commentCount: Int?
}

struct GatherManifestChapter: Encodable {
    let title: String
    let index: Int
}

struct GatherManifestClip: Encodable {
    let id: String
    let videoId: String
    let sourceUrl: String
    let title: String
    let uploader: String?
    /// Relative path to MP4 from the manifest's directory (e.g. `"./01_Lex_01-14-32.mp4"`).
    let mp4Path: String
    /// Relative path to SRT, or `null` when no transcript exists (whole file omitted — §C.4).
    let srtPath: String?
    /// `"none"` when no transcript was available; `"local"` when blocks came from the archive.
    let transcriptSource: String?
    /// Logical clip start before pad is applied (L0 from Step 3 `GatherResolvedClip`).
    let logicalStartSeconds: Double
    /// Logical clip end before pad is applied (L1).
    let logicalEndSeconds: Double
    let padSeconds: Double
    /// Actual start fed to ffmpeg: `max(0, L0 - pad)`.
    let paddedStartSeconds: Double
    /// Actual end fed to ffmpeg: `L1 + pad` (clamped to duration when known).
    let paddedEndSeconds: Double
    let engagement: GatherManifestEngagement?
    let chapter: GatherManifestChapter?
    /// Literal shell command to reproduce this exact clip with the same pad (and Step 5 flags).
    let reproduceCommand: String
    /// `true` only if the whole-cue rule had to be overridden (currently always `false`).
    let srtCuesTrimmed: Bool
    // MARK: Step 5 fields
    /// Relative path to the JPEG thumbnail extracted at logical start (L0), or `null`.
    let thumbnailPath: String?
    /// `true` when `--embed-source` was on and the clip mux succeeded.
    let embedSourceApplied: Bool
    /// Populated when embed was skipped or partially applied — otherwise `null`.
    let embedSourceNote: String?
    /// Encode mode used: `"copy"` (--fast), `"default"` (re-encode + VideoToolbox), or `"exact"` (--exact, libx264 CRF 18).
    let encodeMode: String
}

struct GatherManifest: Encodable {
    let schemaVersion: Int
    let query: String
    let padSeconds: Double
    let generatedAt: String
    /// `true` when the run used `--thumbnails`.
    let thumbnailsEnabled: Bool
    /// `true` when the run used `--embed-source`.
    let embedSourceEnabled: Bool
    /// Encode mode for this run: `"copy"` (--fast), `"default"`, or `"exact"` (--exact).
    let encodeMode: String
    let clips: [GatherManifestClip]

    init(
        query: String,
        padSeconds: Double,
        generatedAt: String,
        thumbnailsEnabled: Bool,
        embedSourceEnabled: Bool,
        encodeMode: String,
        clips: [GatherManifestClip]
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

enum GatherSidecarWriter {

    /// Write `manifest.json` and `clips.md` into `outputDir`.
    ///
    /// Both writes are non-atomic best-effort — failures are non-fatal for the
    /// gather run (caller should surface them as warnings, not hard errors).
    static func write(
        clips: [GatherManifestClip],
        query: String,
        padSeconds: Double,
        outputDir: String,
        thumbnailsEnabled: Bool,
        embedSourceEnabled: Bool,
        encodeMode: String
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
    // Note: No Step 5 fields (thumbnail paths / embed status) in clips.md — keep it
    // text-only so imports into Obsidian, Notion, etc. do not gain broken local image links.

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
