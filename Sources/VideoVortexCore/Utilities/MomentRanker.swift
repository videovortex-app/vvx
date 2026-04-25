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
                momentCandidates: config.includeCandidates ? [] : nil,
                rejectedAnchors: config.includeCandidates ? [] : nil
            )
        }

        let metadataTopicTerms = extractKeywords(
            ([result.title, result.description ?? ""] + result.tags + result.chapters.map(\.title))
                .joined(separator: " ")
        )
        let topicTerms = metadataTopicTerms.union(dominantTranscriptTerms(blocks))

        let generated = generateCandidates(
            blocks: blocks,
            chapters: result.chapters,
            topicTerms: topicTerms,
            config: config
        )

        let candidates = generated.candidates
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
        let orderedSelected = selected.sorted {
            let leftScore = min(100, max(0, $0.candidate.baseScore + $0.diversityBonus))
            let rightScore = min(100, max(0, $1.candidate.baseScore + $1.diversityBonus))
            if leftScore != rightScore { return leftScore > rightScore }
            if $0.candidate.baseScore != $1.candidate.baseScore {
                return $0.candidate.baseScore > $1.candidate.baseScore
            }
            return $0.candidate.startSeconds < $1.candidate.startSeconds
        }

        let rankedMoments = orderedSelected.enumerated().map { idx, selectedCandidate in
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
            momentCandidates: config.includeCandidates ? Array(rankedCandidates) : nil,
            rejectedAnchors: config.includeCandidates ? generated.rejectedAnchors : nil
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
    let centerSentence: String?
    let anchorScore: Int?
    let anchorBreakdown: MomentAnchorBreakdown?
    let topicAlignment: Int?
    let chapterSpecificity: Double?
    let numberIsTopicAligned: Bool?
    let hasConsequenceNearby: Bool?
    let anchorRejected: Bool?
    let rejectionReason: String?
    let productWorthinessSignals: [String]

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
            whySelected: Array((why + extraWhy).prefix(5)),
            centerSentence: centerSentence,
            anchorScore: anchorScore,
            anchorBreakdown: anchorBreakdown,
            topicAlignment: topicAlignment,
            chapterSpecificity: chapterSpecificity.map(roundConfidence),
            numberIsTopicAligned: numberIsTopicAligned,
            hasConsequenceNearby: hasConsequenceNearby,
            anchorRejected: anchorRejected,
            rejectionReason: rejectionReason,
            productWorthinessSignals: productWorthinessSignals.isEmpty ? nil : productWorthinessSignals
        )
    }
}

private struct SelectedCandidate {
    let candidate: MomentCandidate
    let diversityBonus: Int
}

private struct ImpactUnit {
    let index: Int
    let startSeconds: Double
    let endSeconds: Double
    let text: String
    let chapterIndex: Int?
    let blockRange: ClosedRange<Int>
    let anchorScore: Int
    let anchorBreakdown: MomentAnchorBreakdown
    let topicAlignment: Int
    let chapterSpecificity: Double
    let numberIsTopicAligned: Bool
    let hasConsequenceNearby: Bool
    let productWorthinessSignals: [String]
    let rejectionReason: String?

    var durationSeconds: Double { endSeconds - startSeconds }
}

private struct AnchorEvaluation {
    let breakdown: MomentAnchorBreakdown
    let topicAlignment: Int
    let chapterSpecificity: Double
    let numberIsTopicAligned: Bool
    let hasConsequenceNearby: Bool
    let productWorthinessSignals: [String]
    let rejectionReason: String?
}

private struct CandidateGenerationResult {
    let candidates: [MomentCandidate]
    let rejectedAnchors: [RejectedMomentAnchor]
}

private func generateCandidates(
    blocks: [TranscriptBlock],
    chapters: [VideoChapter],
    topicTerms: Set<String>,
    config: MomentRankerConfig
) -> CandidateGenerationResult {
    let anchorCandidates = generateAnchorCandidates(
        blocks: blocks,
        chapters: chapters,
        topicTerms: topicTerms,
        config: config
    )

    if anchorCandidates.candidates.count >= min(config.limit, 4) {
        return anchorCandidates
    }

    let fallbackCandidates = generateWindowCandidates(
        blocks: blocks,
        chapters: chapters,
        topicTerms: topicTerms,
        config: config
    )

    var seen = Set<String>()
    var merged: [MomentCandidate] = []
    for candidate in anchorCandidates.candidates + fallbackCandidates {
        let key = "\(Int(candidate.startSeconds.rounded()))-\(Int(candidate.endSeconds.rounded()))"
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        merged.append(candidate)
    }
    return CandidateGenerationResult(
        candidates: merged,
        rejectedAnchors: anchorCandidates.rejectedAnchors
    )
}

private func generateWindowCandidates(
    blocks: [TranscriptBlock],
    chapters: [VideoChapter],
    topicTerms: Set<String>,
    config: MomentRankerConfig
) -> [MomentCandidate] {
    var windows: [(start: Int, end: Int)] = []
    var seen = Set<String>()
    let blockScores = blocks.map { blockSignalScore($0.text) }
    let blockTopicScores = blocks.map {
        topicRelevanceScore(keywords: extractKeywords($0.text), topicTerms: topicTerms)
    }

    func addWindow(start: Int) {
        guard let window = buildWindow(blocks: blocks, startIndex: start, config: config) else { return }
        let key = "\(window.start)-\(window.end)"
        guard !seen.contains(key) else { return }
        seen.insert(key)
        windows.append(window)
    }

    let transcriptDuration = max(0.0, (blocks.last?.endSeconds ?? 0) - (blocks.first?.startSeconds ?? 0))
    let strideSeedBudget = max(config.maxCandidateCount, config.limit * 16)
    let effectiveStride = max(config.strideSeconds, transcriptDuration / Double(strideSeedBudget))
    var lastStart = -Double.infinity
    for (idx, block) in blocks.enumerated() {
        if block.startSeconds - lastStart >= effectiveStride {
            addWindow(start: idx)
            lastStart = block.startSeconds
        }
    }

    let signalSeedBudget = max(config.limit * 8, 24)
    let signalSeeds = blockScores.enumerated()
        .filter { $0.element > 0 }
        .sorted {
            if $0.element != $1.element { return $0.element > $1.element }
            return blocks[$0.offset].startSeconds < blocks[$1.offset].startSeconds
        }
        .prefix(signalSeedBudget)

    for seed in signalSeeds {
        addWindow(start: max(0, seed.offset - 2))
    }

    for chapterIdx in chapters.indices {
        if let first = blocks.firstIndex(where: { $0.chapterIndex == chapterIdx }) {
            addWindow(start: first)
        }
    }

    let requestedWindowBudget = config.limit <= 4 ? 16 : max(config.limit * 4, 16)
    let windowBudget = min(config.maxCandidateCount, requestedWindowBudget)
    let prioritizedWindows = windows
        .map { window in
            (
                window: window,
                score: cheapWindowScore(
                    window: window,
                    blocks: blocks,
                    blockScores: blockScores,
                    blockTopicScores: blockTopicScores,
                    topicTerms: topicTerms
                )
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return blocks[$0.window.start].startSeconds < blocks[$1.window.start].startSeconds
        }
        .prefix(windowBudget)
        .map(\.window)

    return prioritizedWindows.compactMap { window in
        makeCandidate(
            blocks: blocks,
            range: window.start ... window.end,
            chapters: chapters,
            topicTerms: topicTerms,
            config: config
        )
    }
}

private func generateAnchorCandidates(
    blocks: [TranscriptBlock],
    chapters: [VideoChapter],
    topicTerms: Set<String>,
    config: MomentRankerConfig
) -> CandidateGenerationResult {
    let units = buildImpactUnits(blocks: blocks, chapters: chapters, topicTerms: topicTerms)
    guard !units.isEmpty else {
        return CandidateGenerationResult(candidates: [], rejectedAnchors: [])
    }

    let anchorBudget = min(units.count, max(config.maxCandidateCount, config.limit * 16))
    let anchors = units
        .filter { $0.anchorScore > 0 || $0.rejectionReason != nil }
        .sorted {
            if $0.anchorScore != $1.anchorScore { return $0.anchorScore > $1.anchorScore }
            return $0.startSeconds < $1.startSeconds
        }
        .prefix(anchorBudget)

    var candidates: [MomentCandidate] = []
    var rejectedAnchors: [RejectedMomentAnchor] = []
    var seen = Set<String>()

    for anchor in anchors {
        if let rejectionReason = anchor.rejectionReason {
            rejectedAnchors.append(
                rejectedAnchor(
                    anchor,
                    chapters: chapters,
                    id: "r\(rejectedAnchors.count + 1)",
                    reason: rejectionReason
                )
            )
            continue
        }

        let range = expandAnchorWindow(
            units: units,
            anchorIndex: anchor.index,
            config: config
        )
        let start = units[range.lowerBound].startSeconds
        let end = units[range.upperBound].endSeconds
        let key = "\(Int((start / 3.0).rounded()))-\(Int((end / 3.0).rounded()))"
        guard !seen.contains(key) else { continue }
        seen.insert(key)

        guard let candidate = makeAnchorCandidate(
            units: units,
            range: range,
            anchor: anchor,
            chapters: chapters,
            topicTerms: topicTerms,
            config: config
        ) else { continue }
        candidates.append(candidate)
    }

    return CandidateGenerationResult(
        candidates: candidates,
        rejectedAnchors: Array(rejectedAnchors.prefix(config.maxCandidateCount))
    )
}

private func buildImpactUnits(
    blocks: [TranscriptBlock],
    chapters: [VideoChapter],
    topicTerms: Set<String>
) -> [ImpactUnit] {
    struct PendingUnit {
        var startSeconds: Double
        var endSeconds: Double
        var chapterIndex: Int?
        var firstBlockIndex: Int
        var lastBlockIndex: Int
        var parts: [String]
    }

    var rawUnits: [(start: Double, end: Double, text: String, chapter: Int?, blockRange: ClosedRange<Int>)] = []
    var pending: PendingUnit?
    var streamTokens: [String] = []

    func flushPending() {
        guard let current = pending else { return }
        let text = finalizeAnchorText(stitchTextSegments(current.parts))
        if wordCount(text) >= 4 {
            rawUnits.append((
                start: current.startSeconds,
                end: current.endSeconds,
                text: text,
                chapter: current.chapterIndex,
                blockRange: current.firstBlockIndex ... current.lastBlockIndex
            ))
        }
        pending = nil
    }

    for (blockArrayIndex, block) in blocks.enumerated() {
        let incomingTokens = block.text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let overlap = tokenOverlapSuffixPrefix(
            left: streamTokens,
            right: incomingTokens,
            maxCount: 50
        )
        let newTokens = Array(incomingTokens.dropFirst(overlap))
        guard !newTokens.isEmpty else { continue }

        streamTokens.append(contentsOf: newTokens)
        if streamTokens.count > 100 {
            streamTokens = Array(streamTokens.suffix(100))
        }

        let blockText = cleanTranscript(newTokens.joined(separator: " "))
        guard !blockText.isEmpty else { continue }

        if let current = pending,
           current.chapterIndex != block.chapterIndex {
            flushPending()
        }

        let segments = splitTranscriptSegments(blockText)
        for segment in segments {
            let segmentText = cleanTranscript(segment)
            guard !segmentText.isEmpty else { continue }

            if segmentText.hasPrefix(">>"), pending != nil {
                flushPending()
            }

            if pending == nil {
                pending = PendingUnit(
                    startSeconds: block.startSeconds,
                    endSeconds: block.endSeconds,
                    chapterIndex: block.chapterIndex,
                    firstBlockIndex: blockArrayIndex,
                    lastBlockIndex: blockArrayIndex,
                    parts: []
                )
            }

            pending?.endSeconds = block.endSeconds
            pending?.lastBlockIndex = blockArrayIndex
            pending?.parts.append(segmentText)

            let combined = pending.map { stitchTextSegments($0.parts) } ?? ""
            let duration = pending.map { block.endSeconds - $0.startSeconds } ?? 0
            let shouldFlush = endsLikelyComplete(segmentText)
                || wordCount(combined) >= 36
                || duration >= 12.0

            if shouldFlush {
                flushPending()
            }
        }
    }

    flushPending()

    return rawUnits.enumerated().map { index, raw in
        let chapterTitle = raw.chapter.flatMap { chapters.indices.contains($0) ? chapters[$0].title : nil }
        let evaluation = anchorEvaluation(
            text: raw.text,
            chapterTitle: chapterTitle,
            topicTerms: topicTerms
        )
        return ImpactUnit(
            index: index,
            startSeconds: raw.start,
            endSeconds: raw.end,
            text: raw.text,
            chapterIndex: raw.chapter,
            blockRange: raw.blockRange,
            anchorScore: max(0, evaluation.breakdown.score),
            anchorBreakdown: evaluation.breakdown,
            topicAlignment: evaluation.topicAlignment,
            chapterSpecificity: evaluation.chapterSpecificity,
            numberIsTopicAligned: evaluation.numberIsTopicAligned,
            hasConsequenceNearby: evaluation.hasConsequenceNearby,
            productWorthinessSignals: evaluation.productWorthinessSignals,
            rejectionReason: evaluation.rejectionReason
        )
    }
}

private func splitTranscriptSegments(_ text: String) -> [String] {
    let speakerSplit = text
        .replacingOccurrences(of: ">>", with: "\u{1E}>>")
        .split(separator: "\u{1E}", omittingEmptySubsequences: true)
        .map(String.init)

    let chunks = speakerSplit.isEmpty ? [text] : speakerSplit
    return chunks.flatMap { chunk in
        let ranges = sentenceRanges(in: chunk)
        return ranges.map { String(chunk[$0]) }
    }
}

private func finalizeAnchorText(_ text: String) -> String {
    var cleaned = cleanTranscript(text)
    cleaned = cleaned.replacingOccurrences(
        of: #"(^|\s)>>\s*"#,
        with: " ",
        options: .regularExpression
    )
    cleaned = collapseRepeatedWords(cleanTranscript(cleaned))
    cleaned = stripLeadingFiller(cleaned)
    cleaned = normalizeLeadingFalseStarts(cleaned)
    cleaned = trimTrailingFiller(cleaned)
    return cleanTranscript(cleaned)
}

private func anchorEvaluation(
    text: String,
    chapterTitle: String?,
    topicTerms: Set<String>
) -> AnchorEvaluation {
    let lower = text.lowercased()
    let keywords = extractKeywords(text)

    let consequenceHits = countMatches(
        lower,
        phrases: [
            "this means", "so now", "because of this", "the implication",
            "therefore", "which is why", "that's why", "as a result",
            "resulted in", "because"
        ]
    )
    let contrastHits = countMatches(
        lower,
        phrases: [
            "but", "however", "instead of", "rather than", "compared to",
            "versus", "tradeoff", "on the other hand"
        ]
    )
    let hasConsequenceNearby = hasConsequenceLanguage(lower) || contrastHits > 0
    let decisionHits = countMatches(
        lower,
        phrases: [
            "realized", "decided", "mistake", "the key", "the trick",
            "what changed", "greater than", "less than", "had to", "has to",
            "have to", "needed to", "needs to"
        ]
    )
    let noveltyHits = countMatches(
        lower,
        phrases: [
            "surprising", "surprised", "counterintuitive", "turns out",
            "nobody", "weird", "wild", "crazy", "all-time", "obvious in hindsight"
        ]
    )
    let outcomeHits = countMatches(
        lower,
        phrases: [
            "result", "worked", "failed", "saved", "grew", "launched",
            "shipped", "change", "changed", "changes", "unlocked", "won",
            "lost", "payoff"
        ]
    )
    let processHits = countMatches(
        lower,
        phrases: [
            "first", "then", "next", "click", "install", "open the",
            "download", "setup", "step", "go to"
        ]
    )

    let hasDigit = lower.range(of: #"\d"#, options: .regularExpression) != nil
    let numberIsTopicAligned = hasDigit && isNumberTopicAligned(
        text: text,
        topicTerms: topicTerms,
        chapterTitle: chapterTitle
    )
    let concretePhraseHits = countMatches(
        lower,
        phrases: [
            "$", "%", "percent", "x faster", "times", "minutes", "seconds",
            "hours", "days", "million", "billion", "revenue", "cost",
            "price", "cheaper", "faster", "slower", "ltv", "cac", "benchmark"
        ]
    )

    var consequence = min(28, consequenceHits * 10)
    let contrast = min(20, contrastHits * 7)
    let decision = min(22, decisionHits * 7)
    var concrete = min(26, (hasDigit ? 8 : 0) + concretePhraseHits * 5)
    let novelty = min(14, noveltyHits * 5)
    var outcome = min(16, outcomeHits * 5)
    let topic = topicAlignmentScore(
        keywords: keywords,
        text: text,
        topicTerms: topicTerms,
        chapterTitle: chapterTitle
    )

    if consequenceHits > 0, hasDigit {
        concrete = min(30, concrete + 7)
        outcome = min(18, outcome + 4)
    }
    if contrastHits > 0, hasDigit {
        consequence = min(26, consequence + 4)
        concrete = min(30, concrete + 5)
    }

    if hasDigit, !numberIsTopicAligned {
        concrete = Int((Double(concrete) * 0.25).rounded(.down))
    }
    if hasDigit, !hasConsequenceNearby {
        concrete = Int((Double(concrete) * 0.5).rounded(.down))
    }

    let processPenalty: Int
    if processHits >= 2 {
        processPenalty = -20
    } else if processHits == 1, consequenceHits + contrastHits + decisionHits + outcomeHits == 0 {
        processPenalty = -8
    } else {
        processPenalty = 0
    }

    var anchorQualityPenalty = 0
    if startsLikelyIncomplete(text) { anchorQualityPenalty -= 10 }
    if endsLikelyIncomplete(text), wordCount(text) >= 10 { anchorQualityPenalty -= 12 }
    if let last = normalizedTokens(text).last, weakEndTokens.contains(last) {
        anchorQualityPenalty -= 12
    }
    if wordCount(text) < 6 { anchorQualityPenalty -= 8 }
    if contextBlockLooksPromotional(text) { anchorQualityPenalty -= 35 }
    anchorQualityPenalty += podcastFluffPenalty(lower)
    if isQuestionAnchor(text) { anchorQualityPenalty -= 20 }
    if endsWithDanglingPhrase(text) { anchorQualityPenalty -= 25 }
    if isProcessSetupAnchor(lower) { anchorQualityPenalty -= 18 }
    if isRandomAnecdoteAnchor(lower) { anchorQualityPenalty -= 16 }
    if hasDanglingPronounStart(text) { anchorQualityPenalty -= 5 }

    let breakdown = MomentAnchorBreakdown(
        consequence: consequence,
        contrast: contrast,
        decision: decision,
        concrete: concrete,
        novelty: novelty,
        outcome: outcome,
        topic: topic,
        processPenalty: processPenalty,
        qualityPenalty: anchorQualityPenalty
    )

    let productWorthinessSignals = deriveProductWorthinessSignals(
        text: text,
        breakdown: breakdown,
        hasNumber: hasDigit,
        numberIsTopicAligned: numberIsTopicAligned,
        hasConsequenceNearby: hasConsequenceNearby
    )
    let rejectionReason = anchorRejectionReason(
        text: text,
        breakdown: breakdown,
        topicAlignment: topic,
        hasConsequenceNearby: hasConsequenceNearby,
        productWorthinessSignals: productWorthinessSignals
    )

    return AnchorEvaluation(
        breakdown: breakdown,
        topicAlignment: topic,
        chapterSpecificity: chapterSpecificityScore(chapterTitle),
        numberIsTopicAligned: numberIsTopicAligned,
        hasConsequenceNearby: hasConsequenceNearby,
        productWorthinessSignals: productWorthinessSignals,
        rejectionReason: rejectionReason
    )
}

private func rejectedAnchor(
    _ anchor: ImpactUnit,
    chapters: [VideoChapter],
    id: String,
    reason: String
) -> RejectedMomentAnchor {
    let chapterContext = resolveChapterContext(
        startSeconds: anchor.startSeconds,
        preferredIndex: anchor.chapterIndex,
        chapters: chapters
    )

    return RejectedMomentAnchor(
        id: id,
        startSeconds: roundTime(anchor.startSeconds),
        endSeconds: roundTime(anchor.endSeconds),
        centerSentence: capitalizeMomentStart(finalizeAnchorText(anchor.text)),
        chapterTitle: chapterContext.title,
        chapterIndex: chapterContext.index,
        anchorScore: anchor.anchorScore,
        anchorBreakdown: anchor.anchorBreakdown,
        topicAlignment: anchor.topicAlignment,
        chapterSpecificity: roundConfidence(anchor.chapterSpecificity),
        numberIsTopicAligned: anchor.numberIsTopicAligned,
        hasConsequenceNearby: anchor.hasConsequenceNearby,
        rejectionReason: reason,
        productWorthinessSignals: anchor.productWorthinessSignals
    )
}

private func topicAlignmentScore(
    keywords: Set<String>,
    text: String,
    topicTerms: Set<String>,
    chapterTitle: String?
) -> Int {
    let chapterTerms = chapterTitle.map(extractKeywords) ?? Set<String>()
    let chapterOverlap = keywords.intersection(chapterTerms).count
    let topicOverlap = keywords.intersection(topicTerms).count

    let numberContext = numberContextTokens(text)
    let contextChapterOverlap = numberContext.intersection(chapterTerms).count
    let contextTopicOverlap = numberContext.intersection(topicTerms).count

    return min(
        12,
        (chapterOverlap * 4)
            + min(6, topicOverlap * 2)
            + (contextChapterOverlap * 4)
            + min(4, contextTopicOverlap * 2)
    )
}

private func isNumberTopicAligned(
    text: String,
    topicTerms: Set<String>,
    chapterTitle: String?
) -> Bool {
    let contextTokens = numberContextTokens(text)
    guard !contextTokens.isEmpty else { return false }

    let chapterTerms = chapterTitle.map(extractKeywords) ?? Set<String>()
    if !contextTokens.intersection(chapterTerms).isEmpty { return true }
    if !contextTokens.intersection(topicTerms).isEmpty { return true }

    let evidenceTerms: Set<String> = [
        "cost", "costs", "price", "pricing", "cheaper", "expensive", "revenue",
        "margin", "margins", "profit", "profits", "ltv", "cac", "tokens",
        "token", "faster", "slower", "efficiency", "benchmark", "benchmarks",
        "users", "customers", "companies", "model", "models", "automation",
        "automations"
    ]
    return !contextTokens.intersection(evidenceTerms).isEmpty
}

private func numberContextTokens(_ text: String, radius: Int = 8) -> Set<String> {
    let tokens = text
        .split(whereSeparator: \.isWhitespace)
        .map { normalizedToken(String($0)) }
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return [] }

    var context = Set<String>()
    for (idx, token) in tokens.enumerated() where token.range(of: #"\d"#, options: .regularExpression) != nil {
        let start = max(0, idx - radius)
        let end = min(tokens.count - 1, idx + radius)
        for token in tokens[start ... end] where token.count >= 3 && !stopwords.contains(token) {
            context.insert(token)
        }
    }
    return context
}

private func hasConsequenceLanguage(_ lower: String) -> Bool {
    let phrases = [
        "because", "so now", "so that", "this means", "therefore", "as a result",
        "enables", "allows", "lets", "changes", "changed", "forces", "forced",
        "reduces", "reduced", "increases", "increased", "saves", "saved",
        "costs", "worth", "risk", "risky", "unlocks", "unlocked", "leads to",
        "which is why", "that's why", "the result"
    ]
    return phrases.contains(where: lower.contains)
}

private func chapterSpecificityScore(_ chapterTitle: String?) -> Double {
    guard let title = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
          !title.isEmpty else { return 0.8 }

    let lower = title.lowercased()
    if isIntroChapterTitle(lower) || isAdChapterTitle(lower) {
        return 0.25
    }

    let lowSignal = [
        "closing thoughts", "intro", "introduction", "outro", "demo", "part 1",
        "part 2", "discussion", "q&a", "qa", "overview", "background"
    ]
    if lowSignal.contains(where: lower.contains) {
        return 0.55
    }

    let highSignal = [
        "why", "how", "cost", "pricing", "cheaper", "fails", "failure",
        "mistake", "benchmark", "analysis", "growth", "risk", "security",
        "automation", "strategy", "decision", "lesson", "secret"
    ]
    let keywords = extractKeywords(title)
    var score = 0.8
    if keywords.count >= 3 { score += 0.15 }
    if highSignal.contains(where: lower.contains) { score += 0.25 }
    if lower.range(of: #"\d"#, options: .regularExpression) != nil { score += 0.1 }
    return min(1.25, score)
}

private func podcastFluffPenalty(_ lower: String) -> Int {
    let hardFluff = [
        "on the show", "on the podcast", "my guest today", "before we start",
        "before we get started", "talking after me", "after me but", "welcome back",
        "thanks for coming", "thanks for being here"
    ]
    if hardFluff.contains(where: lower.contains) { return -24 }

    let softFluff = [
        "if i had to guess", "walk me through", "tell me about", "talk about",
        "what are the biggest", "what do you think", "can you talk", "i'm curious",
        "you mentioned", "before we started recording"
    ]
    return softFluff.contains(where: lower.contains) ? -14 : 0
}

private func isQuestionAnchor(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if trimmed.hasSuffix("?") { return true }

    let questionMarks = trimmed.filter { $0 == "?" }.count
    guard questionMarks > 0 else { return false }

    let lower = trimmed.lowercased()
    let questionStarts = [
        "what ", "why ", "how ", "when ", "where ", "who ", "can you ",
        "could you ", "do you ", "does ", "did ", "is ", "are "
    ]
    return questionStarts.contains(where: lower.hasPrefix)
}

private func endsWithDanglingPhrase(_ text: String) -> Bool {
    let tokens = normalizedTokens(text)
    guard let last = tokens.last else { return false }

    if weakEndTokens.contains(last) { return true }

    let danglingLastTokens: Set<String> = [
        "i", "we", "you", "they", "he", "she", "my", "your", "their", "our"
    ]
    if danglingLastTokens.contains(last) { return true }

    let suffixes: [[String]] = [
        ["before", "we"], ["before", "you"], ["because", "we"], ["because", "you"],
        ["and", "we"], ["and", "you"], ["but", "we"], ["but", "you"],
        ["if", "we"], ["if", "you"], ["when", "we"], ["when", "you"]
    ]
    return suffixes.contains { suffix in
        tokens.count >= suffix.count && Array(tokens.suffix(suffix.count)) == suffix
    }
}

private func isProcessSetupAnchor(_ lower: String) -> Bool {
    let phrases = [
        "all right, so the first thing",
        "all right so the first thing",
        "the first thing",
        "first thing uh",
        "the way that i found",
        "let's go to",
        "go to this link",
        "copy your api key",
        "paste it into",
        "select deepseek",
        "let's test"
    ]
    return phrases.contains(where: lower.contains)
}

private func isRandomAnecdoteAnchor(_ lower: String) -> Bool {
    let phrases = [
        "i was like but",
        "it was just weird",
        "that was just weird",
        "i don't know he died",
        "i had to guess",
        "i have to imagine",
        "do you want to come to my office"
    ]
    return phrases.contains(where: lower.contains)
}

private func hasDanglingPronounStart(_ text: String) -> Bool {
    let tokens = normalizedTokens(text)
    guard let first = tokens.first else { return false }
    let danglingStarts: Set<String> = ["it", "they", "he", "she", "this", "that", "these", "those", "most"]
    guard danglingStarts.contains(first) else { return false }

    let hasNumber = tokens.contains { $0.range(of: #"\d"#, options: .regularExpression) != nil }
    let hasNamedSubjectCue = tokens.contains {
        ["model", "company", "companies", "product", "users", "customers", "team", "founders", "workflow", "agent", "agents"].contains($0)
    }
    return !hasNumber && !hasNamedSubjectCue
}

private func deriveProductWorthinessSignals(
    text: String,
    breakdown: MomentAnchorBreakdown,
    hasNumber: Bool,
    numberIsTopicAligned: Bool,
    hasConsequenceNearby: Bool
) -> [String] {
    let lower = text.lowercased()
    var signals: [String] = []
    if breakdown.consequence > 0 || hasConsequenceNearby { signals.append("consequence") }
    if breakdown.contrast >= 7 { signals.append("strong_contrast") }
    if breakdown.decision >= 7 { signals.append("decision_point") }
    let hasActionableRule = lower.contains("should")
        || lower.contains("need to")
        || lower.contains("the key")
        || (lower.contains("have to") && !lower.contains("i have to imagine"))
    if hasActionableRule {
        signals.append("actionable_rule")
    }
    if breakdown.novelty > 0 || lower.contains("surprising") || lower.contains("counterintuitive") || lower.contains("turns out") {
        signals.append("surprising_claim")
    }
    if hasNumber, numberIsTopicAligned, hasConsequenceNearby {
        signals.append("topic_aligned_number")
    }
    if breakdown.concrete >= 14, numberIsTopicAligned || breakdown.topic >= 4 {
        signals.append("topic_aligned_concrete_evidence")
    }
    return Array(Set(signals)).sorted()
}

private func anchorRejectionReason(
    text: String,
    breakdown: MomentAnchorBreakdown,
    topicAlignment: Int,
    hasConsequenceNearby: Bool,
    productWorthinessSignals: [String]
) -> String? {
    let lower = text.lowercased()
    if contextBlockLooksPromotional(text) { return "sponsor_or_cta" }
    if isQuestionAnchor(text) { return "question_anchor" }
    if endsWithDanglingPhrase(text) { return "incomplete_fragment" }
    if isProcessSetupAnchor(lower) { return "process_or_setup" }
    if isRandomAnecdoteAnchor(lower), topicAlignment < 4, breakdown.concrete < 14 {
        return "random_anecdote"
    }
    if podcastFluffPenalty(lower) <= -20 { return "podcast_or_admin_fluff" }
    if podcastFluffPenalty(lower) < 0, breakdown.consequence == 0, breakdown.contrast == 0 {
        return "interviewer_setup"
    }

    let score = max(0, breakdown.score)
    if score < 12 { return "anchor_score_below_threshold" }
    if topicAlignment == 0, breakdown.consequence == 0, breakdown.contrast == 0, breakdown.decision == 0 {
        return "no_topic_or_consequence"
    }
    if productWorthinessSignals.isEmpty {
        return "not_product_worthy"
    }
    if !hasConsequenceNearby,
       breakdown.contrast == 0,
       breakdown.decision == 0,
       breakdown.novelty == 0,
       breakdown.concrete < 14 {
        return "no_consequence_nearby"
    }
    return nil
}

private func expandAnchorWindow(
    units: [ImpactUnit],
    anchorIndex: Int,
    config: MomentRankerConfig
) -> ClosedRange<Int> {
    guard units.indices.contains(anchorIndex) else { return 0 ... 0 }

    let maxDuration = anchorMaxDuration(config)
    let targetDuration = anchorTargetDuration(config, maxDuration: maxDuration)
    let minDuration = anchorMinDuration(config, targetDuration: targetDuration)
    let beforeGoal = min(12.0, targetDuration * 0.32)

    var startIndex = anchorIndex
    var endIndex = anchorIndex
    let anchorChapter = units[anchorIndex].chapterIndex

    func duration(_ start: Int, _ end: Int) -> Double {
        units[end].endSeconds - units[start].startSeconds
    }

    func beforeDuration() -> Double {
        units[anchorIndex].startSeconds - units[startIndex].startSeconds
    }

    func canAddPrevious() -> Bool {
        guard startIndex > 0 else { return false }
        let previous = units[startIndex - 1]
        let gap = max(0.0, units[startIndex].startSeconds - previous.endSeconds)
        guard gap <= 4.0 else { return false }
        guard units[endIndex].endSeconds - previous.startSeconds <= maxDuration else { return false }
        if let anchorChapter,
           let previousChapter = previous.chapterIndex,
           previousChapter != anchorChapter,
           duration(startIndex, endIndex) >= minDuration,
           rollingTokenOverlap(previous.text, units[startIndex].text) < 2,
           !startsLikelyIncomplete(units[startIndex].text) {
            return false
        }
        return !contextBlockLooksPromotional(previous.text)
    }

    func canAddNext() -> Bool {
        guard endIndex + 1 < units.count else { return false }
        let next = units[endIndex + 1]
        let gap = max(0.0, next.startSeconds - units[endIndex].endSeconds)
        guard gap <= 4.0 else { return false }
        guard next.endSeconds - units[startIndex].startSeconds <= maxDuration else { return false }
        let overlap = rollingTokenOverlap(units[endIndex].text, next.text)
        let currentLast = units[endIndex].text
            .split(whereSeparator: \.isWhitespace)
            .last
            .map { normalizedToken(String($0)) } ?? ""
        let currentNeedsContinuation = weakEndTokens.contains(currentLast)
        if startsLikelyIncomplete(next.text),
           overlap < 2,
           !currentNeedsContinuation,
           duration(startIndex, endIndex) >= minDuration {
            return false
        }
        if let anchorChapter,
           let nextChapter = next.chapterIndex,
           nextChapter != anchorChapter,
           duration(startIndex, endIndex) >= minDuration,
           overlap < 2,
           !endsLikelyIncomplete(units[endIndex].text) {
            return false
        }
        return !contextBlockLooksPromotional(next.text)
    }

    var guardCount = 0
    while beforeDuration() < beforeGoal, canAddPrevious(), guardCount < 12 {
        startIndex -= 1
        guardCount += 1
    }

    guardCount = 0
    while duration(startIndex, endIndex) < targetDuration, guardCount < 28 {
        guardCount += 1
        if canAddNext() {
            endIndex += 1
        } else if canAddPrevious() {
            startIndex -= 1
        } else {
            break
        }
    }

    guardCount = 0
    while duration(startIndex, endIndex) < minDuration, guardCount < 16 {
        guardCount += 1
        if canAddNext() {
            endIndex += 1
        } else if canAddPrevious() {
            startIndex -= 1
        } else {
            break
        }
    }

    while startIndex < anchorIndex,
          startsLikelyIncomplete(units[startIndex].text),
          units[endIndex].endSeconds - units[startIndex + 1].startSeconds >= minDuration {
        startIndex += 1
    }

    while endIndex > anchorIndex,
          endsLikelyIncomplete(units[endIndex].text),
          units[endIndex - 1].endSeconds - units[startIndex].startSeconds >= minDuration {
        endIndex -= 1
    }

    return startIndex ... endIndex
}

private func makeAnchorCandidate(
    units: [ImpactUnit],
    range: ClosedRange<Int>,
    anchor: ImpactUnit,
    chapters: [VideoChapter],
    topicTerms: Set<String>,
    config: MomentRankerConfig
) -> MomentCandidate? {
    let startIndex = max(0, range.lowerBound)
    let endIndex = min(units.count - 1, range.upperBound)
    guard startIndex <= endIndex else { return nil }

    let windowUnits = Array(units[startIndex ... endIndex])
    guard let first = windowUnits.first, let last = windowUnits.last else { return nil }

    let rawText = stitchTextSegments(windowUnits.map(\.text))
    let text = finalizeMomentText(rawText)
    guard !text.isEmpty else { return nil }
    let centerSentence = capitalizeMomentStart(finalizeAnchorText(anchor.text))
    guard containsAnchorMeaning(text: text, anchor: centerSentence) else { return nil }

    let words = wordCount(text)
    guard words >= 16 else { return nil }

    let chapterContext = resolveChapterContext(
        startSeconds: anchor.startSeconds,
        preferredIndex: anchor.chapterIndex,
        chapters: chapters
    )
    let chapterIndex = chapterContext.index
    let chapterTitle = chapterContext.title
    let lower = text.lowercased()
    guard !isHardRejectedLeadIn(text: rawText.lowercased(), chapterTitle: chapterTitle),
          !isHardRejectedLeadIn(text: lower, chapterTitle: chapterTitle) else { return nil }

    let keywords = extractKeywords(text)
    let topicScore = topicRelevanceScore(keywords: keywords, topicTerms: topicTerms)
    let anchorImpact = min(28, max(0, anchor.anchorScore / 2))
    let insightScore = min(28, max(insightScore(lower), anchorImpact))
    let concreteScore = min(30, max(concretenessScore(lower), anchor.anchorBreakdown.concrete))
    let selfContained = selfContainedScore(text: text, wordCount: words)
    let rawChapterScore = chapterScore(
        chapterTitle: chapterTitle,
        chapterIndex: chapterIndex,
        firstStart: first.startSeconds,
        chapters: chapters
    )
    let chapterScore = min(14, max(0, Int((Double(rawChapterScore) * anchor.chapterSpecificity).rounded())))
    let qualityPenalty = max(-45, qualityPenalty(
        text: lower,
        wordCount: words,
        chapterTitle: chapterTitle,
        startSeconds: first.startSeconds
    ) + min(0, anchor.anchorBreakdown.processPenalty))

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

    var why = whySelected(
        topicScore: topicScore,
        insightScore: insightScore,
        concreteScore: concreteScore,
        selfContained: selfContained,
        chapterScore: chapterScore,
        qualityPenalty: qualityPenalty
    )
    if anchor.anchorScore >= 20 {
        why.insert("centered on high-impact sentence", at: 0)
    }

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
        why: Array(why.prefix(6)),
        centerSentence: centerSentence,
        anchorScore: anchor.anchorScore,
        anchorBreakdown: anchor.anchorBreakdown,
        topicAlignment: anchor.topicAlignment,
        chapterSpecificity: anchor.chapterSpecificity,
        numberIsTopicAligned: anchor.numberIsTopicAligned,
        hasConsequenceNearby: anchor.hasConsequenceNearby,
        anchorRejected: false,
        rejectionReason: nil,
        productWorthinessSignals: anchor.productWorthinessSignals
    )
}

private func anchorMaxDuration(_ config: MomentRankerConfig) -> Double {
    if config.targetDurationSeconds < 20.0 { return config.maxDurationSeconds }
    return min(config.maxDurationSeconds, 44.0)
}

private func anchorTargetDuration(_ config: MomentRankerConfig, maxDuration: Double) -> Double {
    if config.targetDurationSeconds < 20.0 { return config.targetDurationSeconds }
    return min(maxDuration, max(config.minDurationSeconds, 36.0))
}

private func anchorMinDuration(_ config: MomentRankerConfig, targetDuration: Double) -> Double {
    if config.targetDurationSeconds < 20.0 { return min(config.minDurationSeconds, targetDuration) }
    return min(20.0, targetDuration)
}

private func countMatches(_ text: String, phrases: [String]) -> Int {
    phrases.reduce(0) { total, phrase in
        total + (text.contains(phrase) ? 1 : 0)
    }
}

private func containsAnchorMeaning(text: String, anchor: String) -> Bool {
    let anchorTokens = normalizedTokens(anchor)
        .filter { $0.count >= 4 && !stopwords.contains($0) && Int($0) == nil }
    guard anchorTokens.count >= 3 else { return true }

    let textTokenSet = Set(normalizedTokens(text))
    let hits = anchorTokens.filter { textTokenSet.contains($0) }.count
    return Double(hits) / Double(anchorTokens.count) >= 0.55
}

private func endsLikelyComplete(_ text: String) -> Bool {
    guard let finalCharacter = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
        return false
    }
    return ".?!".contains(finalCharacter)
}

private func cheapWindowScore(
    window: (start: Int, end: Int),
    blocks: [TranscriptBlock],
    blockScores: [Int],
    blockTopicScores: [Int],
    topicTerms: Set<String>
) -> Int {
    guard blocks.indices.contains(window.start),
          blocks.indices.contains(window.end) else { return 0 }

    let width = max(1, window.end - window.start + 1)
    let stride = max(1, width / 10)
    var score = 0
    var sampled = 0

    var idx = window.start
    while idx <= window.end {
        score += blockScores[idx] * 3
        score += topicTerms.isEmpty ? 0 : blockTopicScores[idx]
        sampled += 1
        idx += stride
    }

    let first = blocks[window.start]
    if let chapterIndex = first.chapterIndex,
       window.start == blocks.firstIndex(where: { $0.chapterIndex == chapterIndex }) {
        score += 16
    }
    if startsLikelyIncomplete(first.text) { score -= 8 }
    if contextBlockLooksPromotional(first.text) { score -= 30 }

    return score + min(10, sampled)
}

private func buildWindow(
    blocks: [TranscriptBlock],
    startIndex: Int,
    config: MomentRankerConfig
) -> (start: Int, end: Int)? {
    guard blocks.indices.contains(startIndex) else { return nil }
    let startSeconds = blocks[startIndex].startSeconds
    let startChapterIndex = blocks[startIndex].chapterIndex
    var endIndex = startIndex

    while endIndex + 1 < blocks.count {
        let nextBlock = blocks[endIndex + 1]
        if let startChapterIndex,
           let nextChapterIndex = nextBlock.chapterIndex,
           nextChapterIndex != startChapterIndex,
           blocks[endIndex].endSeconds - startSeconds >= config.minDurationSeconds {
            break
        }

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

private func refineBoundaryRange(
    blocks: [TranscriptBlock],
    range: ClosedRange<Int>,
    config: MomentRankerConfig
) -> ClosedRange<Int> {
    guard !blocks.isEmpty else { return range }
    var startIndex = max(0, range.lowerBound)
    var endIndex = min(blocks.count - 1, range.upperBound)
    guard startIndex <= endIndex else { return range }

    startIndex = expandStartBoundary(
        blocks: blocks,
        startIndex: startIndex,
        endIndex: endIndex,
        config: config
    )
    endIndex = expandEndBoundary(
        blocks: blocks,
        startIndex: startIndex,
        endIndex: endIndex,
        config: config
    )

    return startIndex ... endIndex
}

private func expandStartBoundary(
    blocks: [TranscriptBlock],
    startIndex: Int,
    endIndex: Int,
    config: MomentRankerConfig
) -> Int {
    var startIndex = startIndex
    var expansions = 0

    while startIndex > 0, expansions < 4 {
        let previousIndex = startIndex - 1
        let current = blocks[startIndex]
        let previous = blocks[previousIndex]

        let lookaheadEnd = min(endIndex, startIndex + 2)
        let currentText = stitchBlockTexts(Array(blocks[startIndex ... lookaheadEnd]))
        let startsIncomplete = startsLikelyIncomplete(currentText)
        let hasOverlap = hasRollingCaptionOverlap(previous, current)
        let shouldExpand = startsIncomplete || hasOverlap

        guard shouldExpand else { break }
        guard canBorrowBoundaryBlock(
            borrowed: previous,
            adjacent: current,
            opposite: blocks[endIndex],
            allowCrossChapter: startsIncomplete || hasOverlap,
            config: config
        ) else { break }
        startIndex = previousIndex
        expansions += 1
    }

    return startIndex
}

private func expandEndBoundary(
    blocks: [TranscriptBlock],
    startIndex: Int,
    endIndex: Int,
    config: MomentRankerConfig
) -> Int {
    var endIndex = endIndex
    var expansions = 0

    while endIndex + 1 < blocks.count, expansions < 4 {
        let current = blocks[endIndex]
        let next = blocks[endIndex + 1]

        let lookbackStart = max(startIndex, endIndex - 2)
        let currentText = stitchBlockTexts(Array(blocks[lookbackStart ... endIndex]))
        guard endsLikelyIncomplete(currentText) else { break }
        guard canBorrowBoundaryBlock(
            borrowed: next,
            adjacent: current,
            opposite: blocks[startIndex],
            allowCrossChapter: hasRollingCaptionOverlap(current, next),
            config: config
        ) else { break }

        endIndex += 1
        expansions += 1
    }

    return endIndex
}

private func canBorrowBoundaryBlock(
    borrowed: TranscriptBlock,
    adjacent: TranscriptBlock,
    opposite: TranscriptBlock,
    allowCrossChapter: Bool,
    config: MomentRankerConfig
) -> Bool {
    canBorrowBoundaryBlock(
        borrowed: borrowed,
        adjacent: adjacent,
        opposite: opposite,
        allowCrossChapter: allowCrossChapter,
        maxDurationSeconds: config.maxDurationSeconds
    )
}

private func canBorrowBoundaryBlock(
    borrowed: TranscriptBlock,
    adjacent: TranscriptBlock,
    opposite: TranscriptBlock,
    allowCrossChapter: Bool,
    maxDurationSeconds: Double
) -> Bool {
    if let borrowedChapter = borrowed.chapterIndex,
       let adjacentChapter = adjacent.chapterIndex,
       borrowedChapter != adjacentChapter,
       !allowCrossChapter {
        return false
    }

    let gap = max(
        0.0,
        max(borrowed.startSeconds, adjacent.startSeconds) - min(borrowed.endSeconds, adjacent.endSeconds)
    )
    guard gap <= 3.0 else { return false }

    let start = min(borrowed.startSeconds, opposite.startSeconds)
    let end = max(borrowed.endSeconds, opposite.endSeconds)
    guard end - start <= maxDurationSeconds else { return false }

    return !contextBlockLooksPromotional(borrowed.text)
}

private func hasRollingCaptionOverlap(_ lhs: TranscriptBlock, _ rhs: TranscriptBlock) -> Bool {
    rollingTokenOverlap(lhs.text, rhs.text) >= 2 || rollingTokenOverlap(rhs.text, lhs.text) >= 2
}

private func compressAroundPayoffRange(
    blocks: [TranscriptBlock],
    range: ClosedRange<Int>,
    topicTerms: Set<String>,
    config: MomentRankerConfig
) -> ClosedRange<Int> {
    guard !blocks.isEmpty else { return range }
    let lowerBound = max(0, range.lowerBound)
    let upperBound = min(blocks.count - 1, range.upperBound)
    guard lowerBound <= upperBound else { return range }

    let centerIndex = bestPayoffIndex(
        blocks: blocks,
        range: lowerBound ... upperBound,
        topicTerms: topicTerms
    )
    var startIndex = centerIndex
    var endIndex = centerIndex
    let maxDuration = compactMaxDuration(config)
    let targetDuration = compactTargetDuration(config, maxDuration: maxDuration)
    let minDuration = min(config.minDurationSeconds, maxDuration)

    func duration(_ start: Int, _ end: Int) -> Double {
        blocks[end].endSeconds - blocks[start].startSeconds
    }

    func canAddPrevious() -> Bool {
        guard startIndex > lowerBound else { return false }
        return canBorrowBoundaryBlock(
            borrowed: blocks[startIndex - 1],
            adjacent: blocks[startIndex],
            opposite: blocks[endIndex],
            allowCrossChapter: true,
            maxDurationSeconds: maxDuration
        )
    }

    func canAddNext() -> Bool {
        guard endIndex < upperBound else { return false }
        return canBorrowBoundaryBlock(
            borrowed: blocks[endIndex + 1],
            adjacent: blocks[endIndex],
            opposite: blocks[startIndex],
            allowCrossChapter: true,
            maxDurationSeconds: maxDuration
        )
    }

    var guardCount = 0
    while duration(startIndex, endIndex) < targetDuration, guardCount < 24 {
        guardCount += 1
        let text = stitchBlockTexts(Array(blocks[startIndex ... endIndex]))
        let needsStart = startsLikelyIncomplete(text)
        let needsEnd = endsLikelyIncomplete(text)

        if needsStart, canAddPrevious() {
            startIndex -= 1
            continue
        }
        if needsEnd, canAddNext() {
            endIndex += 1
            continue
        }

        let previousScore = canAddPrevious()
            ? payoffScore(blocks: blocks, index: startIndex - 1, range: lowerBound ... upperBound, topicTerms: topicTerms)
            : Int.min
        let nextScore = canAddNext()
            ? payoffScore(blocks: blocks, index: endIndex + 1, range: lowerBound ... upperBound, topicTerms: topicTerms)
            : Int.min
        if previousScore == Int.min, nextScore == Int.min { break }

        if previousScore > nextScore + 3 {
            startIndex -= 1
        } else {
            endIndex += 1
        }
    }

    while duration(startIndex, endIndex) < minDuration {
        let previousAvailable = canAddPrevious()
        let nextAvailable = canAddNext()
        if !previousAvailable, !nextAvailable { break }
        if nextAvailable {
            endIndex += 1
        } else if previousAvailable {
            startIndex -= 1
        }
    }

    var snapGuard = 0
    while startsLikelyIncomplete(stitchBlockTexts(Array(blocks[startIndex ... endIndex]))),
          canAddPrevious(),
          snapGuard < 4 {
        startIndex -= 1
        snapGuard += 1
    }

    snapGuard = 0
    while endsLikelyIncomplete(stitchBlockTexts(Array(blocks[startIndex ... endIndex]))),
          canAddNext(),
          snapGuard < 4 {
        endIndex += 1
        snapGuard += 1
    }

    return startIndex ... endIndex
}

private func bestPayoffIndex(
    blocks: [TranscriptBlock],
    range: ClosedRange<Int>,
    topicTerms: Set<String>
) -> Int {
    var bestIndex = range.lowerBound
    var bestScore = Int.min

    for index in range {
        let score = payoffScore(blocks: blocks, index: index, range: range, topicTerms: topicTerms)
        if score > bestScore {
            bestScore = score
            bestIndex = index
        }
    }

    return bestIndex
}

private func payoffScore(
    blocks: [TranscriptBlock],
    index: Int,
    range: ClosedRange<Int>,
    topicTerms: Set<String>
) -> Int {
    let start = max(range.lowerBound, index - 1)
    let end = min(range.upperBound, index + 1)
    let text = stitchBlockTexts(Array(blocks[start ... end]))
    let lower = text.lowercased()
    let keywords = extractKeywords(text)

    var score = insightScore(lower) * 2
        + concretenessScore(lower) * 2
        + topicRelevanceScore(keywords: keywords, topicTerms: topicTerms)
        + selfContainedScore(text: text, wordCount: wordCount(text))

    let payoffPhrases = [
        "this means", "the key", "the result", "what i love", "what changed",
        "the mistake", "turns out", "because", "instead of", "compared to",
        "so the", "solves", "that's why", "what matters"
    ]
    score += payoffPhrases.reduce(0) { $0 + (lower.contains($1) ? 7 : 0) }
    if lower.range(of: #"\d"#, options: .regularExpression) != nil { score += 8 }
    if lower.contains(">>") { score += 3 }
    score += fillerPenalty(lower)
    score += leadingFragmentPenalty(lower)

    return score
}

private func alignStartToSpeakerChange(
    blocks: [TranscriptBlock],
    range: ClosedRange<Int>,
    config: MomentRankerConfig
) -> ClosedRange<Int> {
    let startIndex = max(0, range.lowerBound)
    let endIndex = min(blocks.count - 1, range.upperBound)
    guard startIndex < endIndex, blocks.indices.contains(startIndex), blocks.indices.contains(endIndex) else {
        return range
    }

    let maxStartOffset = min(10.0, max(4.0, compactTargetDuration(config, maxDuration: compactMaxDuration(config)) / 3.0))
    let minRemaining = min(config.minDurationSeconds, 18.0)
    for index in (startIndex + 1) ... endIndex {
        let offset = blocks[index].startSeconds - blocks[startIndex].startSeconds
        guard offset <= maxStartOffset else { break }
        guard blocks[endIndex].endSeconds - blocks[index].startSeconds >= minRemaining else { continue }
        guard blockHasSpeakerChange(blocks[index]) else { continue }
        guard !contextBlockLooksPromotional(blocks[index].text) else { continue }
        return index ... endIndex
    }

    return range
}

private func blockHasSpeakerChange(_ block: TranscriptBlock) -> Bool {
    block.text.contains(">>")
}

private func compactMaxDuration(_ config: MomentRankerConfig) -> Double {
    if config.targetDurationSeconds < 20.0 { return config.maxDurationSeconds }
    return min(config.maxDurationSeconds, 42.0)
}

private func compactTargetDuration(_ config: MomentRankerConfig, maxDuration: Double) -> Double {
    if config.targetDurationSeconds < 20.0 { return config.targetDurationSeconds }
    return min(maxDuration, max(config.minDurationSeconds, 34.0))
}

private func compressedBoundaryConfig(_ config: MomentRankerConfig) -> MomentRankerConfig {
    let maxDuration = min(config.maxDurationSeconds, compactMaxDuration(config) + 2.0)
    return MomentRankerConfig(
        limit: config.limit,
        includeCandidates: config.includeCandidates,
        minDurationSeconds: min(config.minDurationSeconds, maxDuration),
        targetDurationSeconds: min(config.targetDurationSeconds, maxDuration),
        maxDurationSeconds: maxDuration,
        strideSeconds: config.strideSeconds,
        qualityThreshold: config.qualityThreshold,
        maxCandidateCount: config.maxCandidateCount
    )
}

private func makeCandidate(
    blocks: [TranscriptBlock],
    range: ClosedRange<Int>,
    chapters: [VideoChapter],
    topicTerms: Set<String>,
    config: MomentRankerConfig
) -> MomentCandidate? {
    let refinedRange = refineBoundaryRange(blocks: blocks, range: range, config: config)
    let compressedRange = compressAroundPayoffRange(
        blocks: blocks,
        range: refinedRange,
        topicTerms: topicTerms,
        config: config
    )
    let readableRange = alignStartToSpeakerChange(
        blocks: blocks,
        range: compressedRange,
        config: config
    )
    let snappedRange = refineBoundaryRange(blocks: blocks, range: readableRange, config: compressedBoundaryConfig(config))
    let windowBlocks = snappedRange.compactMap { blocks.indices.contains($0) ? blocks[$0] : nil }
    guard let first = windowBlocks.first, let last = windowBlocks.last else { return nil }

    let rawText = stitchBlockTexts(windowBlocks)
    let text = finalizeMomentText(rawText)
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
    guard !isHardRejectedLeadIn(text: rawText.lowercased(), chapterTitle: chapterTitle),
          !isHardRejectedLeadIn(text: lower, chapterTitle: chapterTitle) else { return nil }

    let topicScore = topicRelevanceScore(keywords: keywords, topicTerms: topicTerms)
    let hasNumber = lower.range(of: #"\d"#, options: .regularExpression) != nil
    let numberAligned = hasNumber && isNumberTopicAligned(
        text: text,
        topicTerms: topicTerms,
        chapterTitle: chapterTitle
    )
    let hasConsequence = hasConsequenceLanguage(lower)
    let insightScore = insightScore(lower)
    var concreteScore = concretenessScore(lower)
    if hasNumber, !numberAligned {
        concreteScore = Int((Double(concreteScore) * 0.25).rounded(.down))
    }
    if hasNumber, !hasConsequence {
        concreteScore = Int((Double(concreteScore) * 0.5).rounded(.down))
    }
    let selfContained = selfContainedScore(text: text, wordCount: words)
    let specificity = chapterSpecificityScore(chapterTitle)
    let rawChapterScore = chapterScore(
        chapterTitle: chapterTitle,
        chapterIndex: chapterIndex,
        firstStart: first.startSeconds,
        chapters: chapters
    )
    let chapterScore = min(14, max(0, Int((Double(rawChapterScore) * specificity).rounded())))
    let qualityPenalty = qualityPenalty(
        text: lower,
        wordCount: words,
        chapterTitle: chapterTitle,
        startSeconds: first.startSeconds
    )
    let fallbackAnchorBreakdown = MomentAnchorBreakdown(
        consequence: hasConsequence ? min(28, insightScore) : 0,
        contrast: lower.contains("but") || lower.contains("instead of") || lower.contains("compared to") ? 7 : 0,
        decision: lower.contains("the key") || lower.contains("mistake") || lower.contains("should") ? 7 : 0,
        concrete: concreteScore,
        novelty: lower.contains("turns out") || lower.contains("surprising") ? 5 : 0,
        outcome: lower.contains("result") || lower.contains("changed") || lower.contains("saved") ? 5 : 0,
        topic: topicScore,
        processPenalty: 0,
        qualityPenalty: qualityPenalty
    )
    let productSignals = deriveProductWorthinessSignals(
        text: text,
        breakdown: fallbackAnchorBreakdown,
        hasNumber: hasNumber,
        numberIsTopicAligned: numberAligned,
        hasConsequenceNearby: hasConsequence
    )
    guard !productSignals.isEmpty else { return nil }

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
        why: why,
        centerSentence: nil,
        anchorScore: nil,
        anchorBreakdown: nil,
        topicAlignment: topicScore,
        chapterSpecificity: specificity,
        numberIsTopicAligned: hasNumber ? numberAligned : nil,
        hasConsequenceNearby: hasConsequence,
        anchorRejected: false,
        rejectionReason: nil,
        productWorthinessSignals: productSignals
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
    if isLowSignalChapterTitle(lower) { return 0 }

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

private func qualityPenalty(
    text: String,
    wordCount: Int,
    chapterTitle: String?,
    startSeconds: Double
) -> Int {
    var penalty = 0
    if wordCount < 28 { penalty -= 8 }
    if text.range(of: #"\b(um|uh|like|you know)\b"#, options: .regularExpression) != nil { penalty -= 3 }
    if text.range(of: #"\b(\w+)\s+\1\b"#, options: [.regularExpression, .caseInsensitive]) != nil { penalty -= 4 }
    penalty += leadingFragmentPenalty(text)
    penalty += fillerPenalty(text)
    penalty += genericSectionPenalty(chapterTitle: chapterTitle, startSeconds: startSeconds, text: text)
    if text.count > 0 {
        let punctuationCount = text.filter { ".?!,".contains($0) }.count
        if Double(punctuationCount) / Double(text.count) < 0.005 { penalty -= 3 }
    }
    return max(-45, penalty)
}

private func leadingFragmentPenalty(_ text: String) -> Int {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstRaw = trimmed.split(whereSeparator: \.isWhitespace).first else { return 0 }

    let first = normalizedToken(String(firstRaw))

    var penalty = weakStartTokens.contains(first) ? -8 : 0
    if ["uh", "um", "yeah", "okay"].contains(first) { penalty -= 5 }
    if firstRaw.hasSuffix(".") && wordCount(trimmed) > 12 { penalty -= 5 }
    if trimmed.hasPrefix(">>") { penalty -= 2 }

    return max(-12, penalty)
}

private let weakStartTokens: Set<String> = [
    "and", "but", "because", "so", "then", "than", "or", "to", "of",
    "for", "from", "with", "without", "instead", "rather", "into", "out",
    "comes", "came", "coming", "was", "were", "is", "are", "be", "been",
    "being", "does", "did", "do", "has", "have", "had", "edge", "game",
    "guy", "kernel", "approval", "able", "kind", "stuff", "long"
]

private let weakEndTokens: Set<String> = [
    "and", "but", "because", "so", "then", "than", "or", "to", "of",
    "for", "from", "with", "without", "instead", "rather", "into", "out",
    "the", "a", "an", "that", "this", "it", "its", "is", "are", "was",
    "were", "be", "been", "being", "have", "has", "had", "as", "like",
    "which", "who", "what", "why", "how"
]

private func startsLikelyIncomplete(_ text: String) -> Bool {
    let trimmed = stripSpeakerMarkerPrefix(text)
    guard let firstRaw = trimmed.split(whereSeparator: \.isWhitespace).first else { return false }

    let first = normalizedToken(String(firstRaw))
    if weakStartTokens.contains(first) { return true }
    if let scalar = firstRaw.unicodeScalars.first,
       CharacterSet.lowercaseLetters.contains(scalar) {
        return true
    }
    if let firstCharacter = firstRaw.first,
       [",", ";", ":", ")", "]"].contains(firstCharacter) {
        return true
    }
    return false
}

private func endsLikelyIncomplete(_ text: String) -> Bool {
    let trimmed = stripSpeakerMarkerPrefix(text)
    guard let lastRaw = trimmed.split(whereSeparator: \.isWhitespace).last else { return false }

    let last = normalizedToken(String(lastRaw))
    if weakEndTokens.contains(last) { return true }
    guard let finalCharacter = trimmed.last else { return false }
    return !".?!".contains(finalCharacter)
}

private func stripSpeakerMarkerPrefix(_ text: String) -> String {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasPrefix(">>") {
        trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

private func rollingTokenOverlap(_ left: String, _ right: String) -> Int {
    let leftTokens = left
        .split(whereSeparator: \.isWhitespace)
        .map { normalizedToken(String($0)) }
        .filter { !$0.isEmpty }
    let rightTokens = right
        .split(whereSeparator: \.isWhitespace)
        .map { normalizedToken(String($0)) }
        .filter { !$0.isEmpty }
    let maxOverlap = min(leftTokens.count, rightTokens.count, 12)
    guard maxOverlap > 0 else { return 0 }

    for count in stride(from: maxOverlap, through: 1, by: -1) {
        if Array(leftTokens.suffix(count)) == Array(rightTokens.prefix(count)) {
            return count
        }
    }
    return 0
}

private func contextBlockLooksPromotional(_ text: String) -> Bool {
    let lower = text.lowercased()
    if hardLeadInScore(String(lower.prefix(700))) >= 16 { return true }
    let phrases = [
        "vanta.com", "workos.com", "works.com", "supporting sponsor",
        "make sure to subscribe", "click the subscribe", "join the new society",
        "promo code", "use code", "learn more at"
    ]
    return phrases.contains(where: lower.contains)
}

private func fillerPenalty(_ text: String) -> Int {
    let weighted: [(String, Int)] = [
        ("supporting sponsor", -24),
        ("sponsor", -18),
        ("sponsored", -18),
        ("go to works.com", -24),
        ("go to workos.com", -24),
        ("workos.com", -24),
        ("work os allows", -24),
        ("vanta helps", -24),
        ("vanta automates", -24),
        ("vanta.com", -24),
        ("earn and prove trust", -20),
        ("make your app enterprise ready", -20),
        ("as a listener", -14),
        ("learn more at", -12),
        ("customer data", -6),
        ("compliant fast", -12),
        ("go to ", -4),
        ("use code", -12),
        ("promo code", -16),
        ("check out", -8),
        ("make sure to subscribe", -16),
        ("click the subscribe", -16),
        ("not subscribed", -14),
        ("subscribe button", -14),
        ("join the new society", -18),
        ("new society", -12),
        ("link below", -10),
        ("description below", -10),
        ("follow me on", -10),
        ("instagram", -8),
        ("twitter", -8),
        ("complete beginner", -8),
        ("top 1% ai developer", -14),
        ("learn in just three weeks", -14),
        ("you will be able to build anything", -14),
        ("built a full startup", -8),
        ("over 2,000 hours", -8),
        ("my claim is that by the end", -10),
        ("go ahead below the video", -12)
    ]
    let phrasePenalty = weighted.reduce(0) { total, item in
        total + (text.contains(item.0) ? item.1 : 0)
    }
    return max(-35, phrasePenalty + repeatedPhrasePenalty(text))
}

private func isHardRejectedLeadIn(text: String, chapterTitle: String?) -> Bool {
    if isAdChapterTitle(chapterTitle?.lowercased()) { return true }

    let prefix = String(text.prefix(700))
    if hardLeadInScore(prefix) >= 18 { return true }

    return false
}

private func hardLeadInScore(_ text: String) -> Int {
    let weighted: [(String, Int)] = [
        ("supporting sponsor", 18),
        ("sponsored", 18),
        ("vanta.com", 18),
        ("workos.com", 18),
        ("works.com", 16),
        ("promo code", 16),
        ("use code", 14),
        ("as a listener", 14),
        ("learn more at", 10),
        ("$1,000 off", 10),
        ("1,000 off", 10),
        ("make sure to subscribe", 18),
        ("click the subscribe", 18),
        ("join the new society", 18),
        ("learn in just three weeks", 16),
        ("complete beginner", 10),
        ("top 1% ai developer", 14),
    ]
    var score = weighted.reduce(0) { total, item in
        total + (text.contains(item.0) ? item.1 : 0)
    }

    let hasBrandAdTerm = text.range(of: #"\b(vanta|workos|work os)\b"#, options: .regularExpression) != nil
    let hasCommercialCue = text.range(of: #"\b(go to|learn more at|listener|off|promo|code)\b"#, options: .regularExpression) != nil
    if hasBrandAdTerm && hasCommercialCue { score += 12 }

    return score
}

private func genericSectionPenalty(chapterTitle: String?, startSeconds: Double, text: String) -> Int {
    guard let chapterTitle = chapterTitle?.lowercased(), isIntroChapterTitle(chapterTitle) else { return 0 }

    var penalty = -6
    if startSeconds < 120 { penalty -= 5 }
    if insightScore(text) < 10 && concretenessScore(text) < 10 { penalty -= 4 }
    return penalty
}

private func isLowSignalChapterTitle(_ lower: String) -> Bool {
    isIntroChapterTitle(lower)
        || isAdChapterTitle(lower)
        || ["outro", "conclusion", "final thoughts"].contains(where: { lower.contains($0) })
}

private func isIntroChapterTitle(_ lower: String?) -> Bool {
    guard let lower else { return false }
    return ["intro", "introduction"].contains(where: { lower.contains($0) })
}

private func isAdChapterTitle(_ lower: String?) -> Bool {
    guard let lower else { return false }
    return ["sponsor", "ad read", "advertisement", "promo"].contains(where: { lower.contains($0) })
}

private func repeatedPhrasePenalty(_ text: String) -> Int {
    let tokens = text
        .split(whereSeparator: \.isWhitespace)
        .map { normalizedToken(String($0)) }
        .filter { !$0.isEmpty }
    guard tokens.count >= 8 else { return 0 }

    var repeated = 0
    for width in 2 ... 4 {
        var counts: [String: Int] = [:]
        guard tokens.count >= width else { continue }
        for idx in 0 ... (tokens.count - width) {
            let phrase = tokens[idx ..< idx + width].joined(separator: " ")
            counts[phrase, default: 0] += 1
        }
        repeated += counts.values.filter { $0 >= 3 }.count
    }

    return -min(14, repeated * 3)
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

    var pool = candidates.filter {
        $0.baseScore >= qualityThreshold
            && !$0.productWorthinessSignals.isEmpty
            && ($0.anchorScore.map { $0 >= 14 } ?? true)
            && $0.rejectionReason == nil
            && passesFinalProductGate($0)
    }
    guard !pool.isEmpty else { return [] }

    var selected: [SelectedCandidate] = []
    while selected.count < limit, !pool.isEmpty {
        var bestIndex: Int?
        var bestSelectionScore = Int.min
        var bestDiversity = 15
        let selectedChapterCounts = chapterCounts(for: selected.map(\.candidate))

        for idx in pool.indices {
            let candidate = pool[idx]
            let maxSimilarity = selected
                .map { similarity(candidate, $0.candidate) }
                .max() ?? 0.0
            let maxTemporalOverlap = selected
                .map { temporalSimilarity(candidate, $0.candidate) }
                .max() ?? 0.0

            if selected.count > 0,
               (maxSimilarity > 0.82 || maxTemporalOverlap > 0.25) {
                continue
            }

            let sameChapterCount = selectedChapterCounts[chapterKey(candidate)] ?? 0
            if selected.count > 0,
               sameChapterCount >= 2,
               pool.count > limit - selected.count {
                continue
            }

            let diversity = max(0, Int(((1.0 - maxSimilarity) * 15.0).rounded()))
            let selectionScore = candidate.baseScore
                + diversity
                - Int((maxSimilarity * 12.0).rounded())
                - Int((maxTemporalOverlap * 18.0).rounded())
                - (sameChapterCount * 14)
            if selectionScore > bestSelectionScore {
                bestSelectionScore = selectionScore
                bestIndex = idx
                bestDiversity = diversity
            }
        }

        guard let bestIndex else { break }
        selected.append(SelectedCandidate(candidate: pool.remove(at: bestIndex), diversityBonus: bestDiversity))
    }

    return selected
}

private func passesFinalProductGate(_ candidate: MomentCandidate) -> Bool {
    let signals = Set(candidate.productWorthinessSignals)
    let hasNumber = candidate.cleanText.range(of: #"\d"#, options: .regularExpression) != nil
    let topicAlignment = candidate.topicAlignment ?? 0

    if hasNumber,
       candidate.numberIsTopicAligned == false,
       topicAlignment == 0,
       signals.isSubset(of: ["consequence", "strong_contrast"]) {
        return false
    }

    let strongSignals: Set<String> = [
        "strong_contrast",
        "decision_point",
        "actionable_rule",
        "surprising_claim",
        "topic_aligned_number",
        "topic_aligned_concrete_evidence"
    ]

    if !signals.isDisjoint(with: strongSignals) {
        return true
    }

    guard signals == ["consequence"] else { return false }

    let chapterSpecificity = candidate.chapterSpecificity ?? 0.8
    return candidate.baseScore >= 54
        && (topicAlignment >= 8 || chapterSpecificity >= 1.0)
}

private func chapterCounts(for candidates: [MomentCandidate]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for candidate in candidates {
        counts[chapterKey(candidate), default: 0] += 1
    }
    return counts
}

private func chapterKey(_ candidate: MomentCandidate) -> String {
    if let chapterIndex = candidate.chapterIndex { return "idx:\(chapterIndex)" }
    if let chapterTitle = candidate.chapterTitle { return "title:\(chapterTitle.lowercased())" }
    return "time:\(Int(candidate.startSeconds / 120.0))"
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

private func dominantTranscriptTerms(_ blocks: [TranscriptBlock]) -> Set<String> {
    var counts: [String: Int] = [:]
    for block in blocks {
        for token in extractKeywords(block.text) {
            counts[token, default: 0] += 1
        }
    }

    return Set(
        counts
            .filter { $0.value >= 3 }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(36)
            .map(\.key)
    )
}

private func cleanTranscript(_ text: String) -> String {
    text
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func finalizeMomentText(_ text: String) -> String {
    var cleaned = cleanTranscript(text)
    cleaned = snapAfterEarlySpeakerMarker(cleaned)
    cleaned = cleaned.replacingOccurrences(
        of: #"(^|\s)>>\s*"#,
        with: " ",
        options: .regularExpression
    )
    cleaned = collapseRepeatedWords(cleanTranscript(cleaned))
    cleaned = stripLeadingFiller(cleaned)
    cleaned = normalizeLeadingFalseStarts(cleaned)
    cleaned = snapToCompleteSentences(cleaned)
    cleaned = dropRepeatedLeadInSentences(cleaned)
    cleaned = trimTrailingFragment(cleaned)
    cleaned = stripLeadingFiller(cleaned)
    cleaned = normalizeLeadingFalseStarts(cleaned)
    cleaned = trimTrailingFiller(cleaned)
    cleaned = collapseRepeatedWords(cleaned)
    return capitalizeMomentStart(cleanTranscript(cleaned))
}

private func snapAfterEarlySpeakerMarker(_ text: String) -> String {
    guard let range = text.range(of: ">>") else { return text }
    let offset = text.distance(from: text.startIndex, to: range.lowerBound)
    guard offset <= 260 else { return text }

    let suffix = String(text[range.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard wordCount(suffix) >= 18 else { return text }
    return suffix
}

private func stripLeadingFiller(_ text: String) -> String {
    var cleaned = text
    let pattern = #"(?i)^(?:(?:and|but|so|yeah|okay|ok|uh|um|like|right|mhm|no|well|now|actually|i mean|you know)\b[\s,.\-]*)+"#
    for _ in 0 ..< 3 {
        let next = cleaned.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
        if next == cleaned { break }
        cleaned = next
    }
    return cleanTranscript(cleaned)
}

private func normalizeLeadingFalseStarts(_ text: String) -> String {
    var cleaned = cleanTranscript(text)
    let replacements: [(String, String)] = [
        (#"(?i)^we\s+i mean\s+"#, ""),
        (#"(?i)^i think\s+and\s+"#, ""),
        (#"(?i)^i didn't\s+i've\s+i'd\s+"#, "I'd "),
        (#"(?i)^i didn't\s+i'd\s+"#, "I'd "),
        (#"(?i)^i've\s+i'd\s+"#, "I'd ")
    ]
    for replacement in replacements {
        cleaned = cleaned.replacingOccurrences(
            of: replacement.0,
            with: replacement.1,
            options: .regularExpression
        )
    }
    return cleanTranscript(cleaned)
}

private func collapseRepeatedWords(_ text: String) -> String {
    var cleaned = text
    let pattern = #"\b([A-Za-z][A-Za-z']*)\s+\1\b"#
    for _ in 0 ..< 4 {
        let next = cleaned.replacingOccurrences(
            of: pattern,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )
        if next == cleaned { break }
        cleaned = next
    }
    return cleanTranscript(cleaned)
}

private func trimTrailingFiller(_ text: String) -> String {
    var cleaned = cleanTranscript(text)
    let pattern = #"(?i)(?:[\s,.\-]*(?:uh|um|like|right|okay|ok|yeah|you know|i mean|well))+$"#
    for _ in 0 ..< 3 {
        let next = cleaned.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
        if next == cleaned { break }
        cleaned = next
    }
    return cleanTranscript(cleaned)
}

private func trimTrailingFragment(_ text: String) -> String {
    var cleaned = trimTrailingFiller(text)
    guard wordCount(cleaned) >= 18 else { return cleaned }

    if let final = cleaned.last, !".?!".contains(final),
       let terminalRange = cleaned.range(of: #"[.?!]"#, options: [.regularExpression, .backwards]) {
        let prefix = String(cleaned[...terminalRange.lowerBound])
        if wordCount(prefix) >= 18 {
            return cleanTranscript(prefix)
        }
    }

    let fragmentPatterns = [
        #"(?i)\s+(?:i think|i mean|we basically|we've basically)\b[^.?!]{0,150}$"#,
        #"(?i)\s+(?:and|but|so|because|then)\s+(?:i|we|you|they|it|there|that|this|the)\b[^.?!]{0,150}$"#,
        #"(?i)\s+(?:which|that|where|when|who|if)\b[^.?!]{0,130}$"#,
        #"(?i)\s+(?:from|with|for|to|of|into|onto|about)\s+(?:the|a|an|this|that|these|those|my|our|your|their)?\s*[^.?!]{0,90}$"#
    ]

    for pattern in fragmentPatterns {
        guard let range = cleaned.range(of: pattern, options: .regularExpression) else { continue }
        let prefix = String(cleaned[..<range.lowerBound])
        if wordCount(prefix) >= 18 {
            cleaned = prefix
            break
        }
    }

    return trimTrailingFiller(cleaned)
}

private func capitalizeMomentStart(_ text: String) -> String {
    let cleaned = cleanTranscript(text)
    guard let first = cleaned.first else { return cleaned }
    let firstWord = cleaned.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    let preserveLowercasePrefixes = ["iPhone", "iPad", "iOS", "macOS", "eBay"]
    guard !preserveLowercasePrefixes.contains(firstWord) else { return cleaned }
    guard first.isLowercase else { return cleaned }
    return first.uppercased() + String(cleaned.dropFirst())
}

private func snapToCompleteSentences(_ text: String) -> String {
    let cleaned = cleanTranscript(text)
    let sentences = sentenceRanges(in: cleaned)
        .map { String(cleaned[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard sentences.count > 1 else { return cleaned }

    var start = 0
    var end = sentences.count - 1

    while start < end, startsLikelyIncomplete(sentences[start]) {
        let candidate = sentences[(start + 1) ... end].joined(separator: " ")
        guard wordCount(candidate) >= 18 else { break }
        start += 1
    }

    while end > start, endsLikelyIncomplete(sentences[end]) {
        let candidate = sentences[start ..< end].joined(separator: " ")
        guard wordCount(candidate) >= 18 else { break }
        end -= 1
    }

    return cleanTranscript(sentences[start ... end].joined(separator: " "))
}

private func dropRepeatedLeadInSentences(_ text: String) -> String {
    var sentences = sentenceRanges(in: text)
        .map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard sentences.count > 1 else { return text }

    var index = 0
    while index + 1 < sentences.count {
        let currentTokens = normalizedTokens(sentences[index])
        let nextTokens = normalizedTokens(sentences[index + 1])
        let sharedPrefix = commonPrefixCount(currentTokens, nextTokens)

        if sharedPrefix >= 5,
           currentTokens.count <= nextTokens.count + 3 {
            sentences.remove(at: index)
            continue
        }
        index += 1
    }

    return cleanTranscript(sentences.joined(separator: " "))
}

private func normalizedTokens(_ text: String) -> [String] {
    text
        .split(whereSeparator: \.isWhitespace)
        .map { normalizedToken(String($0)) }
        .filter { !$0.isEmpty }
}

private func commonPrefixCount(_ lhs: [String], _ rhs: [String]) -> Int {
    let maxCount = min(lhs.count, rhs.count)
    var count = 0
    while count < maxCount, lhs[count] == rhs[count] {
        count += 1
    }
    return count
}

private func sentenceRanges(in text: String) -> [Range<String.Index>] {
    guard !text.isEmpty else { return [] }
    let ranges = punctuationSentenceRanges(in: text)
    return ranges.isEmpty ? [text.startIndex ..< text.endIndex] : ranges
}

private func punctuationSentenceRanges(in text: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var start = text.startIndex
    var index = text.startIndex
    while index < text.endIndex {
        let character = text[index]
        let next = text.index(after: index)
        if ".?!".contains(character) {
            if character == ".", isDecimalPoint(in: text, at: index) {
                index = next
                continue
            }
            ranges.append(start ..< next)
            start = next
        }
        index = next
    }
    if start < text.endIndex {
        ranges.append(start ..< text.endIndex)
    }
    return ranges
}

private func isDecimalPoint(in text: String, at index: String.Index) -> Bool {
    guard index > text.startIndex else { return false }
    let previous = text[text.index(before: index)]
    guard previous.isNumber else { return false }

    var next = text.index(after: index)
    while next < text.endIndex, text[next].isWhitespace {
        next = text.index(after: next)
    }
    guard next < text.endIndex else { return false }
    return text[next].isNumber
}

private func stitchBlockTexts(_ blocks: [TranscriptBlock]) -> String {
    stitchTextSegments(blocks.map(\.text))
}

private func stitchTextSegments(_ texts: [String]) -> String {
    var stitchedTokens: [String] = []

    for text in texts {
        let incoming = text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !incoming.isEmpty else { continue }

        guard !stitchedTokens.isEmpty else {
            stitchedTokens = incoming
            continue
        }

        let overlap = tokenOverlapSuffixPrefix(
            left: stitchedTokens,
            right: incoming,
            maxCount: 40
        )

        stitchedTokens.append(contentsOf: incoming.dropFirst(overlap))
    }

    return cleanTranscript(stitchedTokens.joined(separator: " "))
}

private func tokenOverlapSuffixPrefix(
    left: [String],
    right: [String],
    maxCount: Int
) -> Int {
    let maxOverlap = min(left.count, right.count, maxCount)
    guard maxOverlap > 0 else { return 0 }

    for count in stride(from: maxOverlap, through: 1, by: -1) {
        let lhs = left.suffix(count).map(normalizedToken)
        let rhs = right.prefix(count).map(normalizedToken)
        if lhs == rhs {
            return count
        }
    }
    return 0
}

private func normalizedToken(_ token: String) -> String {
    token
        .lowercased()
        .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
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
