import Foundation

/// The output of a `vvx sense` operation — structured metadata and transcript,
/// ready for LLM agent consumption.
///
/// JSON output contract (stdout). This is a public API — field names and types
/// are stable across minor versions. Breaking shape changes bump `schemaVersion`.
public struct SenseResult: Codable, Sendable {

    // MARK: - Schema version

    /// Schema version string. Current value: `"3.0"`.
    /// Agents may branch on this to handle shape changes between major versions.
    public let schemaVersion: String

    // MARK: - Status

    /// Always `true`. Agents should check this first.
    public let success: Bool

    // MARK: - Video identity

    /// The original URL that was sensed.
    public let url: String

    /// Cleaned video title.
    public let title: String

    /// Human-readable platform name (YouTube, TikTok, X, Vimeo, etc.).
    public let platform: String?

    /// Channel or uploader name.
    public let uploader: String?

    /// Playback duration in seconds.
    public let durationSeconds: Int?

    /// ISO 8601 upload date (e.g. "2026-01-15"). Derived from yt-dlp's YYYYMMDD field.
    public let uploadDate: String?

    /// Full video description. Not truncated by vvx.
    public let description: String?

    /// `true` if the platform or extractor provided an incomplete description.
    /// `false` in the common case — vvx does not impose a length cap.
    public let descriptionTruncated: Bool

    /// Tags/keywords associated with the video.
    public let tags: [String]

    /// View count at the time of sensing (nil if unavailable).
    public let viewCount: Int?

    /// Like count at the time of sensing (nil if the platform did not expose it).
    public let likeCount: Int?

    /// Comment count at the time of sensing (nil if the platform did not expose it).
    public let commentCount: Int?

    // MARK: - Transcript

    /// Absolute path to the extracted SRT transcript on disk.
    /// Present as an escape hatch for raw SRT access; `transcriptBlocks` is the primary interface.
    public let transcriptPath: String?

    /// Language code of the extracted transcript (e.g. "en").
    public let transcriptLanguage: String?

    /// The subtitle track type used to produce `transcriptBlocks`.
    /// `.none` + empty `transcriptBlocks` is the definitive "no usable transcript" signal.
    public let transcriptSource: TranscriptSource

    /// Inline, agent-ready transcript blocks.
    ///
    /// **Primary transcript surface.** Each block carries its timestamps, cleaned text,
    /// word count, estimated tokens, and chapter index — no second file read needed.
    ///
    /// Empty when:
    ///   - The video has no subtitle track (`transcriptSource == .none`).
    ///   - `--metadata-only` was passed (blocks stripped for bandwidth; `estimatedTokens`
    ///     and chapter `estimatedTokens` are still populated for context-window planning).
    public let transcriptBlocks: [TranscriptBlock]

    /// Estimated token count of the full transcript (word count × 1.3).
    ///
    /// When `transcriptBlocks` is non-empty, this equals
    /// `transcriptBlocks.map(\.estimatedTokens).reduce(0, +)` exactly.
    /// When `transcriptBlocks` is empty due to `--metadata-only`, this still reflects
    /// the full-transcript estimate so agents can plan before fetching sections.
    /// `nil` when `transcriptSource == .none` (no transcript at all).
    public let estimatedTokens: Int?

    // MARK: - Structure

    /// Chapter markers extracted from the video metadata.
    ///
    /// Use chapters as a table-of-contents: read titles, find the relevant section,
    /// then filter `transcriptBlocks` by `chapterIndex`.
    /// Each chapter carries `endTime` and `estimatedTokens` for context-window planning.
    public let chapters: [VideoChapter]

    /// ISO 8601 timestamp of when the sense operation completed.
    public let completedAt: Date

    // MARK: - Slice metadata (Step 10)

    /// `true` when this result was produced by transcript slicing (`--start` / `--end`).
    /// Absent (false) on unsliced results.
    public let sliced: Bool

    /// Start of the slice in seconds. `nil` when not sliced.
    public let sliceStart: Double?

    /// End of the slice in seconds. `nil` when open-ended or not sliced.
    /// Never contains a non-finite value — `Double.infinity` is never serialised.
    public let sliceEnd: Double?

    // MARK: - Init

    public init(
        schemaVersion: String = "3.0",
        url: String,
        title: String,
        platform: String? = nil,
        uploader: String? = nil,
        durationSeconds: Int? = nil,
        uploadDate: String? = nil,
        description: String? = nil,
        descriptionTruncated: Bool = false,
        tags: [String] = [],
        viewCount: Int? = nil,
        likeCount: Int? = nil,
        commentCount: Int? = nil,
        transcriptPath: String? = nil,
        transcriptLanguage: String? = nil,
        transcriptSource: TranscriptSource = .none,
        transcriptBlocks: [TranscriptBlock] = [],
        estimatedTokens: Int? = nil,
        chapters: [VideoChapter] = [],
        completedAt: Date = .now,
        sliced: Bool = false,
        sliceStart: Double? = nil,
        sliceEnd: Double? = nil
    ) {
        self.schemaVersion        = schemaVersion
        self.success              = true
        self.url                  = url
        self.title                = title
        self.platform             = platform
        self.uploader             = uploader
        self.durationSeconds      = durationSeconds
        self.uploadDate           = uploadDate
        self.description          = description
        self.descriptionTruncated = descriptionTruncated
        self.tags                 = tags
        self.viewCount            = viewCount
        self.likeCount            = likeCount
        self.commentCount         = commentCount
        self.transcriptPath       = transcriptPath
        self.transcriptLanguage   = transcriptLanguage
        self.transcriptSource     = transcriptSource
        self.transcriptBlocks     = transcriptBlocks
        self.estimatedTokens      = estimatedTokens
        self.chapters             = chapters
        self.completedAt          = completedAt
        self.sliced               = sliced
        self.sliceStart           = sliceStart
        self.sliceEnd             = sliceEnd
    }
}

// MARK: - Metadata-only variant

extension SenseResult {

    /// Returns a copy of this result with `transcriptBlocks` stripped to `[]`.
    ///
    /// All other fields — including `estimatedTokens`, per-chapter `estimatedTokens`,
    /// chapter `endTime`, and `schemaVersion` — are preserved identically so that agents
    /// can plan context-window usage without downloading the full block array.
    ///
    /// Use this for `--metadata-only` / `metadataOnly: true` output.
    public func withEmptyBlocks() -> SenseResult {
        SenseResult(
            schemaVersion:        schemaVersion,
            url:                  url,
            title:                title,
            platform:             platform,
            uploader:             uploader,
            durationSeconds:      durationSeconds,
            uploadDate:           uploadDate,
            description:          description,
            descriptionTruncated: descriptionTruncated,
            tags:                 tags,
            viewCount:            viewCount,
            likeCount:            likeCount,
            commentCount:         commentCount,
            transcriptPath:       transcriptPath,
            transcriptLanguage:   transcriptLanguage,
            transcriptSource:     transcriptSource,
            transcriptBlocks:     [],              // stripped
            estimatedTokens:      estimatedTokens, // preserved (slice-local or full-transcript total)
            chapters:             chapters,         // preserved (endTime + slice-local estimatedTokens intact)
            completedAt:          completedAt,
            sliced:               sliced,           // propagated from sliced() if applicable
            sliceStart:           sliceStart,
            sliceEnd:             sliceEnd
        )
    }
}

// MARK: - Transcript slicing (Step 10)

extension SenseResult {

    /// Returns a new `SenseResult` containing only the transcript blocks that overlap
    /// the requested time window, with all token and chapter counts recalculated to
    /// reflect the slice exactly.
    ///
    /// **Database integrity rule:** This method must only be called on output destined
    /// for stdout. `vortex.db` must always receive the full unsliced result via
    /// `VortexIndexer.index(senseResult:db:)` before this method is called.
    ///
    /// **Chapter hybrid rule:**
    /// - Chapter `startTime` / `endTime` are **never mutated** — they reflect absolute
    ///   structural boundaries so agents can still issue accurate `vvx clip` commands.
    /// - Chapter `estimatedTokens` **is** recomputed from surviving blocks within the
    ///   slice, so context-window math stays accurate for this payload.
    ///
    /// - Parameters:
    ///   - startSeconds: Start of the slice in seconds. `0.0` for open start.
    ///   - endSeconds: End of the slice in seconds. Pass `Double.infinity` for open end.
    ///                 Non-finite values are never written to `sliceEnd` in JSON.
    /// - Returns: A new `SenseResult` with `sliced = true` and slice-local field values.
    public func sliced(startSeconds: Double, endSeconds: Double) -> SenseResult {
        // Overlap intersection: keep blocks where the block's window crosses the slice.
        // Strict inequalities prevent including blocks that merely touch the boundary.
        let survivingBlocks = transcriptBlocks.filter { block in
            block.endSeconds > startSeconds && block.startSeconds < endSeconds
        }

        // Top-level token parity: nil only when there is no transcript at all.
        // An empty-matching slice emits 0, not nil — there IS a transcript, just
        // nothing in this range.
        let newTokens: Int?
        if transcriptSource == .none {
            newTokens = nil
        } else {
            newTokens = survivingBlocks.map(\.estimatedTokens).reduce(0, +)
        }

        // Chapter hybrid rule: include chapters whose time window intersects the slice;
        // preserve their original timestamps; recompute token counts from surviving blocks.
        let newChapters: [VideoChapter] = chapters.enumerated().compactMap { idx, chapter in
            let chEnd = chapter.endTime ?? Double.infinity
            // Only include chapters that have any time overlap with the slice window.
            guard chapter.startTime < endSeconds && chEnd > startSeconds else { return nil }
            // Surviving blocks within this chapter (by chapterIndex).
            let chapterTokens = survivingBlocks
                .filter { $0.chapterIndex == idx }
                .map(\.estimatedTokens)
                .reduce(0, +)
            // Follow schema convention: nil (not 0) when no blocks survive in this chapter.
            let newChapterTokens: Int? = chapterTokens == 0 ? nil : chapterTokens
            return VideoChapter(
                title:           chapter.title,
                startTime:       chapter.startTime,  // PRESERVED — absolute structural truth
                endTime:         chapter.endTime,     // PRESERVED — absolute structural truth
                estimatedTokens: newChapterTokens
            )
        }

        // sliceEnd for JSON: nil when open-ended so non-finite values never reach Codable.
        let jsonSliceEnd: Double? = endSeconds.isInfinite ? nil : endSeconds

        return SenseResult(
            schemaVersion:        schemaVersion,
            url:                  url,
            title:                title,
            platform:             platform,
            uploader:             uploader,
            durationSeconds:      durationSeconds,
            uploadDate:           uploadDate,
            description:          description,
            descriptionTruncated: descriptionTruncated,
            tags:                 tags,
            viewCount:            viewCount,
            likeCount:            likeCount,
            commentCount:         commentCount,
            transcriptPath:       transcriptPath,
            transcriptLanguage:   transcriptLanguage,
            transcriptSource:     transcriptSource,
            transcriptBlocks:     survivingBlocks,
            estimatedTokens:      newTokens,
            chapters:             newChapters,
            completedAt:          completedAt,
            sliced:               true,
            sliceStart:           startSeconds,
            sliceEnd:             jsonSliceEnd
        )
    }
}

// MARK: - JSON helpers

extension SenseResult {

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting     = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let str  = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    /// Returns just the transcript file contents as plain text (for `--transcript` flag).
    public func transcriptText() -> String? {
        guard let path = transcriptPath else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Returns a formatted Markdown document (for `--markdown` flag).
    ///
    /// Prefers inline `transcriptBlocks` when present; falls back to reading `transcriptPath`.
    public func markdownDocument() -> String {
        var lines: [String] = []
        lines.append("# \(title)")

        var meta: [String] = []
        if let p = platform  { meta.append("**Platform:** \(p)") }
        if let u = uploader  { meta.append("**Channel:** \(u)") }
        if let d = durationSeconds {
            let h = d / 3600; let m = (d % 3600) / 60; let s = d % 60
            let dur = h > 0
                ? String(format: "%d:%02d:%02d", h, m, s)
                : String(format: "%d:%02d", m, s)
            meta.append("**Duration:** \(dur)")
        }
        if let date = uploadDate { meta.append("**Published:** \(date)") }
        if !meta.isEmpty { lines.append(meta.joined(separator: " | ")) }
        lines.append("**URL:** \(url)")

        if let desc = description, !desc.isEmpty {
            lines.append("")
            lines.append("## Description")
            lines.append(desc)
        }

        // Prefer inline blocks; fall back to raw SRT on disk.
        if !transcriptBlocks.isEmpty {
            lines.append("")
            lines.append("## Transcript")
            lines.append(transcriptBlocks.map(\.text).joined(separator: " "))
        } else if let path = transcriptPath,
                  let raw = try? String(contentsOfFile: path, encoding: .utf8),
                  !raw.isEmpty {
            lines.append("")
            lines.append("## Transcript")
            let plainText = SenseResult.stripSRTTimestamps(raw)
            lines.append(plainText)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - SRT helpers

    /// Strip SRT index numbers and timestamp lines, returning clean prose text.
    public static func stripSRTTimestamps(_ srt: String) -> String {
        var result: [String] = []
        let lines = srt.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { i += 1; continue }
            if line.allSatisfy({ $0.isNumber }) { i += 1; continue }
            if line.contains("-->") { i += 1; continue }
            result.append(line)
            i += 1
        }
        return result.joined(separator: " ")
    }
}
