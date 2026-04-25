import Foundation

public struct MomentRankerConfig: Sendable, Equatable {
    public let limit: Int
    public let includeCandidates: Bool
    public let minDurationSeconds: Double
    public let targetDurationSeconds: Double
    public let maxDurationSeconds: Double
    public let strideSeconds: Double
    public let qualityThreshold: Int
    public let maxCandidateCount: Int

    public init(
        limit: Int = 4,
        includeCandidates: Bool = false,
        minDurationSeconds: Double = 20.0,
        targetDurationSeconds: Double = 60.0,
        maxDurationSeconds: Double = 90.0,
        strideSeconds: Double = 18.0,
        qualityThreshold: Int = 28,
        maxCandidateCount: Int = 80
    ) {
        self.limit                 = max(1, limit)
        self.includeCandidates     = includeCandidates
        self.minDurationSeconds    = minDurationSeconds
        self.targetDurationSeconds = targetDurationSeconds
        self.maxDurationSeconds    = maxDurationSeconds
        self.strideSeconds         = strideSeconds
        self.qualityThreshold      = qualityThreshold
        self.maxCandidateCount     = max(1, maxCandidateCount)
    }
}

/// Local, deterministic v1 moment selection.
///
/// This is intentionally not summarization. The ranker generates transcript windows,
/// scores them for insight/concreteness/self-containedness, then applies a small
/// MMR-style diversity pass so the final moments are distinct.
public enum MomentRanker {

    public static func rank(
        result: SenseResult,
        config: MomentRankerConfig = MomentRankerConfig()
    ) -> MomentRankingResult {
        let blocks = result.transcriptBlocks
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startSeconds < $1.startSeconds }

        guard !blocks.isEmpty else {
            return MomentRankingResult(
                sourceTitle: result.title,
                sourceURL: result.url,
                rankedMoments: [],
                momentCandidates: config.includeCandidates ? [] : nil
            )
        }

        let topicTerms = extractKeywords(
            ([result.title, result.description ?? ""] + result.tags + result.chapters.map(\.title))
                .joined(separator: " ")
        )

        let generated = generateCandidates(
            blocks: blocks,
            chapters: result.chapters,
            topicTerms: topicTerms,
            config: config
        )

        let candidates = generated
            .sorted {
                if $0.baseScore != $1.baseScore { return $0.baseScore > $1.baseScore }
                return $0.startSeconds < $1.startSeconds
            }
            .prefix(config.maxCandidateCount)

        let rankedCandidates = candidates.enumerated().map { idx, candidate in
            candidate.asMoment(rank: idx + 1, idPrefix: "c", mmrDiversity: 0)
        }

        let selected = selectWithDiversity(
            candidates: Array(candidates),
            limit: config.limit,
            qualityThreshold: config.qualityThreshold
        )

        let rankedMoments = selected.enumerated().map { idx, selectedCandidate in
            selectedCandidate.candidate.asMoment(
                rank: idx + 1,
                idPrefix: "m",
                mmrDiversity: selectedCandidate.diversityBonus,
                extraWhy: selectedCandidate.diversityBonus >= 10 ? ["distinct from other selected moments"] : []
            )
        }

        return MomentRankingResult(
            sourceTitle: result.title,
            sourceURL: result.url,
            rankedMoments: rankedMoments,
            momentCandidates: config.includeCandidates ? Array(rankedCandidates) : nil
        )
    }

    public static func rankedMoments(
        for result: SenseResult,
        limit: Int = 4
    ) -> [RankedMoment] {
        rank(result: result, config: MomentRankerConfig(limit: limit)).rankedMoments
    }
}

// MARK: - Candidate generation

private struct MomentCandidate {
    let startSeconds: Double
    let endSeconds: Double
    let titleHint: String
    let cleanText: String
    let candidateType: MomentCandidateType
    let confidence: Double
    let chapterTitle: String?
    let chapterIndex: Int?
    let breakdown: MomentScoreBreakdown
    let keywords: Set<String>
    let why: [String]

    var durationSeconds: Double { endSeconds - startSeconds }
    var baseScore: Int { min(85, max(0, breakdown.baseScore)) }

    func asMoment(
        rank: Int,
        idPrefix: String,
        mmrDiversity: Int,
        extraWhy: [String] = []
    ) -> RankedMoment {
        let finalBreakdown = breakdown.withMMRDiversity(mmrDiversity)
        let finalScore = min(100, max(0, baseScore + mmrDiversity))
        return RankedMoment(
            id: "\(idPrefix)\(rank)",
            rank: rank,
            startSeconds: roundTime(startSeconds),
            endSeconds: roundTime(endSeconds),
            durationSeconds: roundTime(durationSeconds),
            titleHint: titleHint,
            cleanText: cleanText,
            score: finalScore,
            candidateType: candidateType,
            confidence: roundConfidence(confidence),
            chapterTitle: chapterTitle,
            chapterIndex: chapterIndex,
            scoreBreakdown: finalBreakdown,
            whySelected: Array((why + extraWhy).prefix(5))
        )
    }
}

private struct SelectedCandidate {
    let candidate: MomentCandidate
    let diversityBonus: Int
}

private func generateCandidates(
    blocks: [TranscriptBlock],
    chapters: [VideoChapter],
    topicTerms: Set<String>,
    config: MomentRankerConfig
) -> [MomentCandidate] {
    var windows: [(start: Int, end: Int)] = []
    var seen = Set<String>()

    func addWindow(start: Int) {
        guard let window = buildWindow(blocks: blocks, startIndex: start, config: config) else { return }
        let key = "\(window.start)-\(window.end)"
        guard !seen.contains(key) else { return }
        seen.insert(key)
        windows.append(window)
    }

    var lastStart = -Double.infinity
    for (idx, block) in blocks.enumerated() {
        if block.startSeconds - lastStart >= config.strideSeconds {
            addWindow(start: idx)
            lastStart = block.startSeconds
        }
    }

    for (idx, block) in blocks.enumerated() where blockSignalScore(block.text) > 0 {
        addWindow(start: max(0, idx - 2))
    }

    for chapterIdx in chapters.indices {
        if let first = blocks.firstIndex(where: { $0.chapterIndex == chapterIdx }) {
            addWindow(start: first)
        }
    }

    return windows.compactMap { window in
        makeCandidate(
            blocks: blocks,
            range: window.start ... window.end,
            chapters: chapters,
            topicTerms: topicTerms,
            config: config
        )
    }
}

private func buildWindow(
    blocks: [TranscriptBlock],
    startIndex: Int,
    config: MomentRankerConfig
) -> (start: Int, end: Int)? {
    guard blocks.indices.contains(startIndex) else { return nil }
    let startSeconds = blocks[startIndex].startSeconds
    var endIndex = startIndex

    while endIndex + 1 < blocks.count {
        let nextEnd = blocks[endIndex + 1].endSeconds
        if nextEnd - startSeconds > config.maxDurationSeconds { break }
        endIndex += 1
        if nextEnd - startSeconds >= config.targetDurationSeconds { break }
    }

    let duration = blocks[endIndex].endSeconds - startSeconds
    if duration < config.minDurationSeconds, startIndex != 0 || endIndex != blocks.count - 1 {
        return nil
    }
    return (startIndex, endIndex)
}

private func makeCandidate(
    blocks: [TranscriptBlock],
    range: ClosedRange<Int>,
    chapters: [VideoChapter],
    topicTerms: Set<String>,
    config: MomentRankerConfig
) -> MomentCandidate? {
    let windowBlocks = range.compactMap { blocks.indices.contains($0) ? blocks[$0] : nil }
    guard let first = windowBlocks.first, let last = windowBlocks.last else { return nil }

    let text = cleanTranscript(windowBlocks.map(\.text).joined(separator: " "))
    guard !text.isEmpty else { return nil }

    let words = wordCount(text)
    guard words >= 18 else { return nil }

    let keywords = extractKeywords(text)
    let chapterContext = resolveChapterContext(
        startSeconds: first.startSeconds,
        preferredIndex: first.chapterIndex,
        chapters: chapters
    )
    let chapterIndex = chapterContext.index
    let chapterTitle = chapterContext.title
    let lower = text.lowercased()

    let topicScore = topicRelevanceScore(keywords: keywords, topicTerms: topicTerms)
    let insightScore = insightScore(lower)
    let concreteScore = concretenessScore(lower)
    let selfContained = selfContainedScore(text: text, wordCount: words)
    let chapterScore = chapterScore(
        chapterTitle: chapterTitle,
        chapterIndex: chapterIndex,
        firstStart: first.startSeconds,
        chapters: chapters
    )
    let qualityPenalty = qualityPenalty(text: lower, wordCount: words)

    let breakdown = MomentScoreBreakdown(
        topicRelevance: topicScore,
        insight: insightScore,
        concreteness: concreteScore,
        selfContained: selfContained,
        chapter: chapterScore,
        qualityPenalty: qualityPenalty
    )
    let base = min(85, max(0, breakdown.baseScore))
    guard base > 0 else { return nil }

    let type = candidateType(
        insight: insightScore,
        concreteness: concreteScore,
        chapter: chapterScore,
        lower: lower
    )

    let why = whySelected(
        topicScore: topicScore,
        insightScore: insightScore,
        concreteScore: concreteScore,
        selfContained: selfContained,
        chapterScore: chapterScore,
        qualityPenalty: qualityPenalty
    )

    return MomentCandidate(
        startSeconds: first.startSeconds,
        endSeconds: last.endSeconds,
        titleHint: titleHint(text: text, chapterTitle: chapterTitle, candidateType: type),
        cleanText: text,
        candidateType: type,
        confidence: Double(base) / 100.0,
        chapterTitle: chapterTitle,
        chapterIndex: chapterIndex,
        breakdown: breakdown,
        keywords: keywords,
        why: why
    )
}

// MARK: - Scoring

private func topicRelevanceScore(keywords: Set<String>, topicTerms: Set<String>) -> Int {
    guard !topicTerms.isEmpty, !keywords.isEmpty else { return 0 }
    let overlap = keywords.intersection(topicTerms).count
    return min(10, overlap * 2)
}

private func insightScore(_ lower: String) -> Int {
    let weighted: [(String, Int)] = [
        ("the reason", 8), ("the key", 8), ("the trick", 8), ("the mistake", 8),
        ("turns out", 8), ("this means", 8), ("what changed", 7), ("we found", 7),
        ("i learned", 7), ("the tradeoff", 7), ("because", 5), ("instead of", 5),
        ("compared to", 5), ("the result", 5), ("surprising", 5), ("actually", 4),
        ("important", 4), ("matters", 4), ("solves", 4), ("decision", 4)
    ]
    return min(28, weighted.reduce(0) { total, item in
        total + (lower.contains(item.0) ? item.1 : 0)
    })
}

private func concretenessScore(_ lower: String) -> Int {
    var score = 0
    if lower.range(of: #"\d"#, options: .regularExpression) != nil { score += 7 }
    if lower.range(of: #"\$|%|percent|x faster|times|minutes|seconds|hours|days"#, options: .regularExpression) != nil { score += 6 }
    let terms = [
        "benchmark", "cost", "price", "cheaper", "faster", "slower", "before",
        "after", "demo", "example", "measured", "tested", "result", "evidence",
        "increase", "decrease", "more than", "less than"
    ]
    score += min(17, terms.reduce(0) { $0 + (lower.contains($1) ? 3 : 0) })
    return min(30, score)
}

private func selfContainedScore(text: String, wordCount: Int) -> Int {
    var score = 0
    if wordCount >= 45 && wordCount <= 220 { score += 8 }
    else if wordCount >= 28 && wordCount <= 280 { score += 5 }
    if text.contains(".") || text.contains("?") || text.contains("!") { score += 4 }
    if text.contains("because") || text.contains("so ") || text.contains("therefore") { score += 3 }

    let firstWords = text.lowercased().split(whereSeparator: \.isWhitespace).prefix(3).map(String.init)
    if let first = firstWords.first, ["it", "this", "that", "they", "he", "she"].contains(first) {
        score -= 3
    }
    return min(16, max(0, score))
}

private func chapterScore(
    chapterTitle: String?,
    chapterIndex: Int?,
    firstStart: Double,
    chapters: [VideoChapter]
) -> Int {
    guard let chapterTitle, let chapterIndex, chapters.indices.contains(chapterIndex) else { return 0 }
    let lower = chapterTitle.lowercased()
    let generic = ["intro", "introduction", "outro", "conclusion", "final thoughts", "sponsor", "ad"]
    if generic.contains(where: { lower.contains($0) }) { return 0 }

    var score = 5
    if firstStart - chapters[chapterIndex].startTime <= 20 { score += 3 }
    if insightScore(lower) > 0 || concretenessScore(lower) > 0 { score += 4 }
    return min(12, score)
}

private func resolveChapterContext(
    startSeconds: Double,
    preferredIndex: Int?,
    chapters: [VideoChapter]
) -> (title: String?, index: Int?) {
    if let preferredIndex, chapters.indices.contains(preferredIndex) {
        let chapter = chapters[preferredIndex]
        let chapterEnd = chapter.endTime ?? Double.infinity
        if startSeconds >= chapter.startTime && startSeconds < chapterEnd {
            return (chapter.title, preferredIndex)
        }
    }

    for (idx, chapter) in chapters.enumerated().reversed() {
        let chapterEnd = chapter.endTime ?? Double.infinity
        if startSeconds >= chapter.startTime && startSeconds < chapterEnd {
            return (chapter.title, idx)
        }
    }

    return (nil, nil)
}

private func qualityPenalty(text: String, wordCount: Int) -> Int {
    var penalty = 0
    if wordCount < 28 { penalty -= 8 }
    if text.range(of: #"\b(um|uh|like|you know)\b"#, options: .regularExpression) != nil { penalty -= 3 }
    if text.range(of: #"\b(\w+)\s+\1\b"#, options: [.regularExpression, .caseInsensitive]) != nil { penalty -= 4 }
    if text.count > 0 {
        let punctuationCount = text.filter { ".?!,".contains($0) }.count
        if Double(punctuationCount) / Double(text.count) < 0.005 { penalty -= 3 }
    }
    return max(-18, penalty)
}

private func blockSignalScore(_ text: String) -> Int {
    let lower = text.lowercased()
    return insightScore(lower) + concretenessScore(lower)
}

private func candidateType(
    insight: Int,
    concreteness: Int,
    chapter: Int,
    lower: String
) -> MomentCandidateType {
    if lower.contains("compared to") || lower.contains("more than") || lower.contains("less than") {
        return .comparison
    }
    if concreteness >= insight && concreteness >= 12 { return .concreteClaim }
    if insight >= 12 { return .insight }
    if chapter >= 8 { return .chapterMoment }
    return .explanation
}

private func whySelected(
    topicScore: Int,
    insightScore: Int,
    concreteScore: Int,
    selfContained: Int,
    chapterScore: Int,
    qualityPenalty: Int
) -> [String] {
    var why: [String] = []
    if insightScore >= 12 { why.append("contains insight language") }
    if concreteScore >= 12 { why.append("contains concrete evidence or comparison") }
    if selfContained >= 10 { why.append("likely self-contained") }
    if topicScore >= 4 { why.append("matches video/topic terms") }
    if chapterScore >= 6 { why.append("aligned with a high-signal chapter") }
    if qualityPenalty < 0 { why.append("minor speech-quality penalty applied") }
    if why.isEmpty { why.append("best available local scoring window") }
    return why
}

// MARK: - MMR diversity

private func selectWithDiversity(
    candidates: [MomentCandidate],
    limit: Int,
    qualityThreshold: Int
) -> [SelectedCandidate] {
    guard !candidates.isEmpty else { return [] }

    var pool = candidates.filter { $0.baseScore >= qualityThreshold }
    if pool.isEmpty {
        pool = Array(candidates.prefix(max(limit * 3, limit)))
    }

    var selected: [SelectedCandidate] = []
    while selected.count < limit, !pool.isEmpty {
        var bestIndex = 0
        var bestSelectionScore = Int.min
        var bestDiversity = 15

        for idx in pool.indices {
            let candidate = pool[idx]
            let maxSimilarity = selected
                .map { similarity(candidate, $0.candidate) }
                .max() ?? 0.0
            let maxTemporalOverlap = selected
                .map { temporalSimilarity(candidate, $0.candidate) }
                .max() ?? 0.0

            if selected.count > 0,
               pool.count > limit - selected.count,
               (maxSimilarity > 0.82 || maxTemporalOverlap > 0.25) {
                continue
            }

            let diversity = max(0, Int(((1.0 - maxSimilarity) * 15.0).rounded()))
            let selectionScore = candidate.baseScore
                + diversity
                - Int((maxSimilarity * 12.0).rounded())
                - Int((maxTemporalOverlap * 18.0).rounded())
            if selectionScore > bestSelectionScore {
                bestSelectionScore = selectionScore
                bestIndex = idx
                bestDiversity = diversity
            }
        }

        selected.append(SelectedCandidate(candidate: pool.remove(at: bestIndex), diversityBonus: bestDiversity))
    }

    return selected
}

private func similarity(_ a: MomentCandidate, _ b: MomentCandidate) -> Double {
    let lexical: Double
    if a.keywords.isEmpty || b.keywords.isEmpty {
        lexical = 0.0
    } else {
        let intersection = a.keywords.intersection(b.keywords).count
        let union = a.keywords.union(b.keywords).count
        lexical = union == 0 ? 0.0 : Double(intersection) / Double(union)
    }

    return max(lexical, temporalSimilarity(a, b))
}

private func temporalSimilarity(_ a: MomentCandidate, _ b: MomentCandidate) -> Double {
    let overlapStart = max(a.startSeconds, b.startSeconds)
    let overlapEnd = min(a.endSeconds, b.endSeconds)
    let overlap = max(0.0, overlapEnd - overlapStart)
    let shorter = max(1.0, min(a.durationSeconds, b.durationSeconds))
    return overlap / shorter
}

// MARK: - Text helpers

private let stopwords: Set<String> = [
    "about", "after", "again", "also", "because", "before", "being", "between",
    "could", "every", "from", "have", "into", "just", "like", "more", "most",
    "much", "only", "over", "really", "some", "than", "that", "their", "them",
    "then", "there", "these", "they", "this", "those", "through", "very", "want",
    "were", "what", "when", "where", "which", "while", "with", "would", "your",
    "you", "and", "the", "for", "are", "but", "not", "was", "all", "can", "our"
]

private func extractKeywords(_ text: String) -> Set<String> {
    let tokens = text
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { $0.count >= 4 && !stopwords.contains($0) && Int($0) == nil }
    return Set(tokens)
}

private func cleanTranscript(_ text: String) -> String {
    text
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
}

private func titleHint(
    text: String,
    chapterTitle: String?,
    candidateType: MomentCandidateType
) -> String {
    if let chapterTitle, !chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return String(chapterTitle.prefix(80))
    }

    let sentences = text
        .components(separatedBy: CharacterSet(charactersIn: ".?!"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.count >= 20 }

    let prefix: String
    switch candidateType {
    case .comparison:    prefix = "Key comparison"
    case .concreteClaim: prefix = "Concrete claim"
    case .chapterMoment: prefix = "Chapter moment"
    case .insight:       prefix = "Insight"
    case .explanation:   prefix = "Explanation"
    }

    guard let first = sentences.first else { return prefix }
    return String(first.prefix(80))
}

private func roundTime(_ value: Double) -> Double {
    (value * 1000.0).rounded() / 1000.0
}

private func roundConfidence(_ value: Double) -> Double {
    (value * 100.0).rounded() / 100.0
}
