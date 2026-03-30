import Foundation

// MARK: - SearchStructuralConfig

public struct SearchStructuralConfig: Sendable {
    public let longestMonologue: Bool    // exactly one of these is true
    public let highDensity:      Bool
    public let monologueGap:     Double  // default: 1.5
    public let densityWindow:    Double  // default: 60.0
    public let limit:            Int
    public let platform:         String?
    public let uploader:         String?
    public let after:            String?

    public init(
        longestMonologue: Bool, highDensity: Bool,
        monologueGap: Double = 1.5, densityWindow: Double = 60.0,
        limit: Int, platform: String? = nil,
        uploader: String? = nil, after: String? = nil
    ) {
        self.longestMonologue = longestMonologue
        self.highDensity      = highDensity
        self.monologueGap     = monologueGap
        self.densityWindow    = densityWindow
        self.limit            = limit
        self.platform         = platform
        self.uploader         = uploader
        self.after            = after
    }
}

// MARK: - SearchProximityConfig

public struct SearchProximityConfig: Sendable {
    public let query:         String    // pre-validated: contains " AND "
    public let withinSeconds: Double    // pre-validated: > 0
    public let limit:         Int
    public let platform:      String?
    public let uploader:      String?
    public let after:         String?

    public init(
        query: String, withinSeconds: Double, limit: Int,
        platform: String? = nil, uploader: String? = nil, after: String? = nil
    ) {
        self.query         = query
        self.withinSeconds = withinSeconds
        self.limit         = limit
        self.platform      = platform
        self.uploader      = uploader
        self.after         = after
    }
}

// MARK: - SearchEngine

public enum SearchEngine {

    /// Structural search (longestMonologue or highDensity).
    /// Returns newline-joined NDJSON: N result lines + 1 StructuralSummaryLine.
    /// On DB failure: returns VvxErrorEnvelope JSON string.
    public static func runStructural(
        config:   SearchStructuralConfig,
        progress: ((String) -> Void)? = nil
    ) async -> String {
        let modeName = config.longestMonologue ? "longest_monologue" : "high_density"

        let db: VortexDB
        do { db = try VortexDB.open() } catch {
            return VvxErrorEnvelope(error: VvxError(
                code: .indexCorrupt,
                message: "Could not open vortex.db: \(error.localizedDescription)"
            )).jsonString()
        }

        let summaries: [VideoSummary]
        do {
            summaries = try await db.videoSummaries(
                platform:  config.platform,
                uploader:  config.uploader,
                afterDate: config.after
            )
        } catch {
            return VvxErrorEnvelope(error: VvxError(
                code: .indexCorrupt,
                message: "Could not query videos: \(error.localizedDescription)"
            )).jsonString()
        }

        progress?("Scanning \(summaries.count) video(s) for structural analysis…")

        struct ScoredResult {
            let summary:   VideoSummary
            let monologue: MonologueSpan?
            let density:   DensitySpan?
            var score: Double {
                monologue.map(\.durationSeconds) ?? density.map(\.wordsPerSecond) ?? 0
            }
        }

        var results: [ScoredResult] = []

        for summary in summaries {
            let blocks: [StoredBlock]
            do { blocks = try await db.blocksForVideo(videoId: summary.id) } catch { continue }
            guard !blocks.isEmpty else { continue }

            if config.longestMonologue {
                if let span = StructuralAnalyzer.longestMonologue(
                    blocks:        blocks,
                    maxGapSeconds: config.monologueGap,
                    chapters:      summary.chapters
                ) {
                    results.append(ScoredResult(summary: summary, monologue: span, density: nil))
                }
            } else {
                if let span = StructuralAnalyzer.highDensityWindow(
                    blocks:        blocks,
                    windowSeconds: config.densityWindow,
                    chapters:      summary.chapters
                ) {
                    results.append(ScoredResult(summary: summary, monologue: nil, density: span))
                }
            }
        }

        results.sort { $0.score > $1.score }
        let topResults = Array(results.prefix(config.limit))

        var lines: [String] = []

        for (i, r) in topResults.enumerated() {
            let rank = i + 1
            if let span = r.monologue {
                let repro = reproduceCommand(videoPath: r.summary.videoPath,
                                             start: span.startSeconds, end: span.endSeconds)
                lines.append(encode(MonologueResultLine(
                    rank:              rank,
                    videoId:           r.summary.id,
                    videoTitle:        r.summary.title,
                    uploader:          r.summary.uploader,
                    platform:          r.summary.platform,
                    uploadDate:        r.summary.uploadDate,
                    videoPath:         r.summary.videoPath,
                    startSeconds:      span.startSeconds,
                    endSeconds:        span.endSeconds,
                    durationSeconds:   span.durationSeconds,
                    blockCount:        span.blockCount,
                    structuralScore:   span.durationSeconds,
                    transcriptExcerpt: span.transcriptExcerpt,
                    chapterTitle:      span.chapterTitle,
                    chapterIndex:      span.chapterIndex,
                    isMultiChapter:    span.isMultiChapter,
                    reproduceCommand:  repro
                )))
            } else if let span = r.density {
                let repro = reproduceCommand(videoPath: r.summary.videoPath,
                                             start: span.startSeconds, end: span.endSeconds)
                lines.append(encode(DensityResultLine(
                    rank:              rank,
                    videoId:           r.summary.id,
                    videoTitle:        r.summary.title,
                    uploader:          r.summary.uploader,
                    platform:          r.summary.platform,
                    uploadDate:        r.summary.uploadDate,
                    videoPath:         r.summary.videoPath,
                    startSeconds:      span.startSeconds,
                    endSeconds:        span.endSeconds,
                    windowSeconds:     config.densityWindow,
                    wordCount:         span.wordCount,
                    wordsPerSecond:    span.wordsPerSecond,
                    structuralScore:   span.wordsPerSecond,
                    transcriptExcerpt: span.transcriptExcerpt,
                    chapterTitle:      span.chapterTitle,
                    chapterIndex:      span.chapterIndex,
                    isMultiChapter:    span.isMultiChapter,
                    reproduceCommand:  repro
                )))
            }
        }

        lines.append(encode(StructuralSummaryLine(
            mode:          modeName,
            scannedVideos: summaries.count,
            resultCount:   topResults.count,
            limit:         config.limit,
            uploader:      config.uploader,
            platform:      config.platform,
            afterDate:     config.after
        )))

        progress?("Found \(topResults.count) result(s) from \(summaries.count) video(s).")
        return lines.joined(separator: "\n")
    }

    /// Proximity search.
    /// Returns newline-joined NDJSON: N result lines + 1 ProximitySummaryLine.
    /// Falls back to empty ProximitySummaryLine if < 2 AND terms parsed.
    /// On DB failure: returns VvxErrorEnvelope JSON string.
    public static func runProximity(
        config:   SearchProximityConfig,
        progress: ((String) -> Void)? = nil
    ) async -> String {
        let withinSeconds = config.withinSeconds

        let rawTerms = config.query
            .components(separatedBy: " AND ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard rawTerms.count >= 2 else {
            // Return empty summary — caller is responsible for validating term count
            return encode(ProximitySummaryLine(
                terms:           rawTerms,
                withinSeconds:   withinSeconds,
                candidateVideos: 0,
                resultCount:     0,
                limit:           config.limit,
                uploader:        config.uploader,
                platform:        config.platform,
                afterDate:       config.after
            ))
        }

        let db: VortexDB
        do { db = try VortexDB.open() } catch {
            return VvxErrorEnvelope(error: VvxError(
                code: .indexCorrupt,
                message: "Could not open vortex.db: \(error.localizedDescription)"
            )).jsonString()
        }

        progress?("Running proximity search: \(rawTerms.joined(separator: " AND ")) within \(withinSeconds)s…")

        let subLimit = max(1000, config.limit * 50)
        var termHitsByVideo: [String: [String: [ProximityHit]]] = [:]
        var videoMeta: [String: SearchHit] = [:]

        for term in rawTerms {
            let hits: [SearchHit]
            do {
                hits = try await db.search(
                    query:     term,
                    platform:  config.platform,
                    afterDate: config.after,
                    uploader:  config.uploader,
                    limit:     subLimit
                )
            } catch {
                return VvxErrorEnvelope(error: VvxError(
                    code: .indexEmpty,
                    message: "Sub-query for term '\(term)' failed: \(error.localizedDescription)"
                )).jsonString()
            }
            for hit in hits {
                let pHit = ProximityHit(
                    term:         term,
                    startSeconds: hit.startSeconds,
                    endSeconds:   hit.endSeconds,
                    text:         hit.text
                )
                termHitsByVideo[hit.videoId, default: [:]][term, default: []].append(pHit)
                if videoMeta[hit.videoId] == nil { videoMeta[hit.videoId] = hit }
            }
        }

        let candidateVideos = termHitsByVideo.filter { $0.value.keys.count == rawTerms.count }
        progress?("Found \(candidateVideos.count) video(s) with all terms present. Scanning for tightest windows…")

        struct ProximityResult {
            let videoId: String
            let meta:    SearchHit
            let window:  ProximityWindow
        }

        var results: [ProximityResult] = []

        for (videoId, termHitsForVideo) in candidateVideos {
            let blocks: [StoredBlock]
            do { blocks = try await db.blocksForVideo(videoId: videoId) } catch { continue }
            if let window = ProximityAnalyzer.minimumWindow(
                termHits:      termHitsForVideo,
                withinSeconds: withinSeconds,
                blocks:        blocks
            ), let meta = videoMeta[videoId] {
                results.append(ProximityResult(videoId: videoId, meta: meta, window: window))
            }
        }

        results.sort { $0.window.proximitySpanSeconds < $1.window.proximitySpanSeconds }
        let topResults = Array(results.prefix(config.limit))

        var lines: [String] = []

        for (i, r) in topResults.enumerated() {
            let rank  = i + 1
            let win   = r.window
            let repro = reproduceCommand(videoPath: r.meta.videoPath,
                                         start: win.startSeconds, end: win.endSeconds)
            lines.append(encode(ProximityResultLine(
                rank:                 rank,
                videoId:              r.videoId,
                videoTitle:           r.meta.title,
                uploader:             r.meta.uploader,
                platform:             r.meta.platform,
                uploadDate:           r.meta.uploadDate,
                videoPath:            r.meta.videoPath,
                startSeconds:         win.startSeconds,
                endSeconds:           win.endSeconds,
                proximitySpanSeconds: win.proximitySpanSeconds,
                withinSeconds:        withinSeconds,
                terms:                rawTerms,
                termHits:             win.termHits.map {
                    ProximityTermHitLine(term: $0.term, startSeconds: $0.startSeconds, text: $0.text)
                },
                structuralScore:      win.proximitySpanSeconds,
                transcriptExcerpt:    win.transcriptExcerpt,
                reproduceCommand:     repro
            )))
        }

        let noWindowNote = topResults.isEmpty && !candidateVideos.isEmpty
        if noWindowNote {
            progress?("No videos had all terms within \(withinSeconds)s. Try a larger --within value.")
        }

        lines.append(encode(ProximitySummaryLine(
            terms:           rawTerms,
            withinSeconds:   withinSeconds,
            candidateVideos: candidateVideos.count,
            resultCount:     topResults.count,
            limit:           config.limit,
            uploader:        config.uploader,
            platform:        config.platform,
            afterDate:       config.after
        )))

        progress?("Found \(topResults.count) proximity window(s) across \(candidateVideos.count) candidate video(s).")
        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private static func reproduceCommand(videoPath: String?, start: Double, end: Double) -> String {
        guard let path = videoPath else { return "" }
        return "vvx clip \"\(path)\" --start \(start) --end \(end)"
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let line = String(data: data, encoding: .utf8) else { return "" }
        return line
    }
}
