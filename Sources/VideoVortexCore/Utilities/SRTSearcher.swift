import Foundation

// MARK: - Context block

/// A single transcript block with its timestamp, used in RAG Markdown context windows.
///
/// Each `ContextBlock` corresponds to one SRT entry (typically 3–5 seconds of speech)
/// immediately before or after the matched hit.
public struct ContextBlock: Sendable, Codable, Equatable {
    /// Human-readable start timestamp with milliseconds stripped, e.g. `"00:14:02"`.
    public let timestamp: String
    /// Plain text content of the block.
    public let text: String
}

// MARK: - Output types

/// A single search result with the matched snippet and its 2-before/2-after context window.
///
/// Conforms to `Codable` so `SearchCommand` can encode it directly to JSON.
public struct SearchResult: Sendable, Codable {
    /// 1-based rank within this result set (1 = most relevant).
    public let rank: Int
    /// FTS5 bm25() score — lower (more negative) means higher relevance.
    public let relevanceScore: Double
    /// Start timestamp of the matched block, e.g. `"00:14:32"`.
    public let timestamp: String
    /// End timestamp of the matched block, e.g. `"00:14:47"`.
    public let timestampEnd: String
    /// Plain text of the matched SRT block.
    public let snippet: String
    /// Joined text of the up-to-2 blocks immediately before the hit (empty string when none).
    public let contextBefore: String
    /// Joined text of the up-to-2 blocks immediately after the hit (empty string when none).
    public let contextAfter: String
    /// Up-to-2 blocks before the hit with individual timestamps (for RAG rendering).
    public let contextBlocksBefore: [ContextBlock]
    /// Up-to-2 blocks after the hit with individual timestamps (for RAG rendering).
    public let contextBlocksAfter: [ContextBlock]
    /// Chapter title from the video creator, if the video has chapters and this hit falls
    /// within one.  `nil` when no chapter data is available or the hit precedes all chapters.
    public let chapterTitle: String?
    public let videoTitle: String
    public let platform: String?
    public let uploader: String?
    public let uploadDate: String?
    /// Filesystem path to the video file; `nil` for sense-only (no download) entries.
    public let videoPath: String?
    /// Filesystem path to the `.srt` transcript file.
    public let transcriptPath: String?
}

/// The full JSON envelope emitted by `vvx search` on stdout (default / non-RAG mode).
public struct SearchOutput: Sendable, Codable {
    public let success: Bool
    public let query: String
    public let totalMatches: Int
    public let results: [SearchResult]

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let str  = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - SRTSearcher

/// FTS5 query executor, context-window assembler, and RAG Markdown renderer.
///
/// **Usage (JSON mode):**
/// ```swift
/// let output = try await SRTSearcher.search(query: "AGI", db: db, limit: 20)
/// print(output.jsonString())
/// ```
///
/// **Usage (RAG mode):**
/// ```swift
/// let output = try await SRTSearcher.search(query: "AGI", db: db, limit: 50)
/// let markdown = SRTSearcher.ragMarkdown(
///     query: "AGI",
///     results: output.results,
///     totalBeforeBudget: output.totalMatches,
///     maxTokens: 5000
/// )
/// print(markdown)
/// ```
///
/// **Context window:**
/// For each FTS5 hit, `SRTSearcher` fetches the full ordered block list for that
/// video (cached within a single `search` call) and returns the 2 blocks immediately
/// before and after the matched block as `contextBefore` / `contextAfter` (plain text)
/// and `contextBlocksBefore` / `contextBlocksAfter` (timestamped, for RAG rendering).
public enum SRTSearcher {

    // MARK: - Public API: JSON search

    /// Execute a full-text search and return results with context windows.
    ///
    /// - Parameters:
    ///   - query: FTS5 query string. Supports boolean operators (`AI AND danger`),
    ///     phrase search (`"exact phrase"`), and Porter-stemmed keywords (`run` matches `running`).
    ///   - db: Opened `VortexDB` actor instance.
    ///   - platform: Optional exact-match filter on the platform column (e.g. `"YouTube"`).
    ///   - afterDate: Optional ISO 8601 date string; only videos uploaded on or after this date.
    ///   - uploader: Optional exact-match filter on the uploader/channel name.
    ///   - limit: Maximum number of results (default 50).
    public static func search(
        query: String,
        db: VortexDB,
        platform: String? = nil,
        afterDate: String? = nil,
        uploader: String? = nil,
        limit: Int = 50
    ) async throws -> SearchOutput {
        let hits = try await db.search(
            query:     query,
            platform:  platform,
            afterDate: afterDate,
            uploader:  uploader,
            limit:     limit
        )

        // Cache blocks per videoId — avoids a round-trip to the DB for every hit
        // from the same video (common when a video has many matching blocks).
        var blocksCache: [String: [StoredBlock]] = [:]

        var results: [SearchResult] = []

        for (idx, hit) in hits.enumerated() {
            let videoBlocks: [StoredBlock]
            if let cached = blocksCache[hit.videoId] {
                videoBlocks = cached
            } else {
                videoBlocks = try await db.blocksForVideo(videoId: hit.videoId)
                blocksCache[hit.videoId] = videoBlocks
            }

            let (before, after, beforeBlocks, afterBlocks) = contextWindow(
                for:    hit.startSeconds,
                blocks: videoBlocks
            )

            let chapter = resolveChapter(startSeconds: hit.startSeconds, chapters: hit.chapters)

            results.append(SearchResult(
                rank:                idx + 1,
                relevanceScore:      hit.relevanceScore,
                timestamp:           formatTimestamp(hit.startTime),
                timestampEnd:        formatTimestamp(hit.endTime),
                snippet:             hit.text,
                contextBefore:       before,
                contextAfter:        after,
                contextBlocksBefore: beforeBlocks,
                contextBlocksAfter:  afterBlocks,
                chapterTitle:        chapter?.title,
                videoTitle:          hit.title,
                platform:            hit.platform,
                uploader:            hit.uploader,
                uploadDate:          hit.uploadDate,
                videoPath:           hit.videoPath,
                transcriptPath:      hit.transcriptPath
            ))
        }

        return SearchOutput(
            success:      true,
            query:        query,
            totalMatches: results.count,
            results:      results
        )
    }

    // MARK: - Public API: RAG Markdown renderer

    /// Render search results as an agent-optimized Markdown context document.
    ///
    /// Each hit is formatted as a fenced section with full source attribution,
    /// a ready-to-run `vvx clip` command, and a timestamped blockquote context window.
    /// Attribution is unambiguous per hit — each section carries title, channel, platform,
    /// timestamp, and file path so an LLM cannot confuse which quote belongs to which video.
    ///
    /// - Parameters:
    ///   - query: The original search query (used in the document header).
    ///   - results: Ranked `SearchResult` array from `search(...)` — must already be in
    ///     relevance order (most relevant first).
    ///   - totalBeforeBudget: The `SearchOutput.totalMatches` value — shown in the header
    ///     and footer so the agent knows the full result set size.
    ///   - maxTokens: Optional hard token budget.  Hits are accumulated in ranked order;
    ///     rendering stops before the accumulated chunk estimate would exceed this cap.
    ///     Token estimation uses `wordCount × 1.3` per chunk.  When `nil`, all results
    ///     are rendered (subject to the `--limit` applied in `search`).
    ///   - versionString: `vvx` version shown in the document header, e.g. `"0.3.0"`.
    ///     Pass an empty string to omit the version from the header.
    /// - Returns: A Markdown string ready to inject into an LLM context window.
    public static func ragMarkdown(
        query: String,
        results: [SearchResult],
        totalBeforeBudget: Int,
        maxTokens: Int? = nil,
        versionString: String = ""
    ) -> String {
        var bodyLines: [String] = []
        var includedCount = 0
        var accumulatedTokens = 0

        for result in results {
            let chunk = renderHitChunk(result, hitNumber: includedCount + 1, total: totalBeforeBudget)
            let chunkTokens = estimateTokens(chunk)
            if let cap = maxTokens, accumulatedTokens + chunkTokens > cap {
                break
            }
            bodyLines.append("")
            bodyLines.append(chunk)
            includedCount += 1
            accumulatedTokens += chunkTokens
        }

        let uniqueVideoCount = Set(results.prefix(includedCount).map(\.videoTitle)).count
        let versionSuffix = versionString.isEmpty ? "" : " — generated by vvx \(versionString)"
        let isTruncated = maxTokens != nil && includedCount < results.count

        var lines: [String] = []
        lines.append("# Search Results: \"\(query)\"")
        if isTruncated {
            lines.append("*\(totalBeforeBudget) match\(totalBeforeBudget == 1 ? "" : "es") (budget: \(maxTokens!) tokens)\(versionSuffix)*")
        } else {
            lines.append("*\(totalBeforeBudget) match\(totalBeforeBudget == 1 ? "" : "es") across \(uniqueVideoCount) video\(uniqueVideoCount == 1 ? "" : "s")\(versionSuffix)*")
        }
        lines.append("")
        lines.append("---")
        lines += bodyLines

        if isTruncated {
            lines.append("")
            lines.append("---")
            lines.append("*Included \(includedCount)/\(totalBeforeBudget) hits to fit max token budget (\(maxTokens!))*")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Internal: hit chunk renderer

    /// Render a single hit as a self-contained Markdown section.
    ///
    /// Format (from §5.1 of VVXPhase3Roadmap.md):
    /// ```
    /// ### Hit N of M: Title — Channel (Platform)
    /// **Timestamp:** HH:MM:SS – HH:MM:SS | **Uploaded:** YYYY-MM-DD
    /// **Chapter:** "Chapter Title" (starts at HH:MM:SS)   ← omitted when no chapter
    /// **File:** `/path/to/video.mp4`                       ← omitted for sense-only
    /// **Clip:** `vvx clip "..." --start ... --end ...`      ← omitted for sense-only
    ///
    /// > [HH:MM:SS] context block before...
    /// > [HH:MM:SS] context block before...
    /// > **[HH:MM:SS] matched snippet...**
    /// > [HH:MM:SS] context block after...
    /// > [HH:MM:SS] context block after...
    ///
    /// ---
    /// ```
    static func renderHitChunk(_ result: SearchResult, hitNumber: Int, total: Int) -> String {
        var lines: [String] = []

        let platformStr  = result.platform.map { " (\($0))" } ?? ""
        let uploaderStr  = result.uploader.map { " — \($0)" } ?? ""
        lines.append("### Hit \(hitNumber) of \(total): \(result.videoTitle)\(uploaderStr)\(platformStr)")

        var meta: [String] = ["**Timestamp:** \(result.timestamp) – \(result.timestampEnd)"]
        if let date = result.uploadDate { meta.append("**Uploaded:** \(date)") }
        lines.append(meta.joined(separator: " | "))

        if let chapterTitle = result.chapterTitle {
            lines.append("**Chapter:** \"\(chapterTitle)\"")
        }

        if let path = result.videoPath {
            lines.append("**File:** `\(path)`")
            lines.append("**Clip:** `vvx clip \"\(path)\" --start \(result.timestamp) --end \(result.timestampEnd)`")
        }

        lines.append("")

        for block in result.contextBlocksBefore {
            lines.append("> [\(block.timestamp)] \(block.text)")
        }
        lines.append("> **[\(result.timestamp)] \(result.snippet)**")
        for block in result.contextBlocksAfter {
            lines.append("> [\(block.timestamp)] \(block.text)")
        }

        lines.append("")
        lines.append("---")

        return lines.joined(separator: "\n")
    }

    // MARK: - Internal: context window

    /// Return the text and timestamped blocks of the 2 entries before and 2 entries after
    /// the block whose `startSeconds` matches `hitStart`.
    ///
    /// Matching is by `startSeconds` equality (the same value stored in both the
    /// `SearchHit` returned by `VortexDB.search` and the `StoredBlock` rows returned
    /// by `VortexDB.blocksForVideo`).
    ///
    /// If the matched block cannot be found in `blocks` (e.g. race condition between
    /// index writes), all return values are empty.
    static func contextWindow(
        for hitStart: Double,
        blocks: [StoredBlock]
    ) -> (before: String, after: String, beforeBlocks: [ContextBlock], afterBlocks: [ContextBlock]) {
        guard let matchIdx = blocks.firstIndex(where: { $0.startSeconds == hitStart }) else {
            return ("", "", [], [])
        }

        let beforeStart  = max(0, matchIdx - 2)
        let beforeSlice  = blocks[beforeStart..<matchIdx]
        let before       = beforeSlice.map(\.text).joined(separator: " ")
        let beforeBlocks = beforeSlice.map { ContextBlock(timestamp: formatTimestamp($0.startTime), text: $0.text) }

        let afterEnd    = min(blocks.count, matchIdx + 3)
        let afterSlice  = blocks[(matchIdx + 1)..<afterEnd]
        let after       = afterSlice.map(\.text).joined(separator: " ")
        let afterBlocks = afterSlice.map { ContextBlock(timestamp: formatTimestamp($0.startTime), text: $0.text) }

        return (before, after, beforeBlocks, afterBlocks)
    }

    // MARK: - Internal: chapter resolution

    /// Find the chapter a hit at `startSeconds` falls within.
    ///
    /// Returns the chapter with the highest `startTime` that is ≤ `startSeconds`.
    /// Returns `nil` when `chapters` is empty or all chapters start after the hit.
    static func resolveChapter(startSeconds: Double, chapters: [VideoChapter]) -> VideoChapter? {
        chapters
            .filter { $0.startTime <= startSeconds }
            .max(by: { $0.startTime < $1.startTime })
    }

    // MARK: - Internal: token estimation

    /// Estimate the token count of `text` using the `wordCount × 1.3` heuristic.
    ///
    /// This is the same estimation used by `--max-tokens` budgeting.
    /// It deliberately over-estimates slightly to leave headroom for Markdown overhead.
    static func estimateTokens(_ text: String) -> Int {
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        return Int((Double(wordCount) * 1.3).rounded())
    }

    // MARK: - Internal: timestamp formatting

    /// Strip the milliseconds component from an SRT timestamp.
    ///
    /// `"00:14:32,000"` → `"00:14:32"`
    /// `"00:14:32.000"` → `"00:14:32"` (yt-dlp dot variant)
    /// Any string without a separator is returned unchanged.
    static func formatTimestamp(_ srtTime: String) -> String {
        if let commaIdx = srtTime.firstIndex(of: ",") {
            return String(srtTime[srtTime.startIndex..<commaIdx])
        }
        if let dotIdx = srtTime.lastIndex(of: ".") {
            // Only strip if the remaining suffix looks like milliseconds (3 digits).
            let suffix = String(srtTime[srtTime.index(after: dotIdx)...])
            if suffix.count == 3, suffix.allSatisfy(\.isNumber) {
                return String(srtTime[srtTime.startIndex..<dotIdx])
            }
        }
        return srtTime
    }
}
