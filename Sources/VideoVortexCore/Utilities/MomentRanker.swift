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
        let contentMode = detectContentMode(result: result, blocks: blocks)

        let generated = generateCandidates(
            blocks: blocks,
            chapters: result.chapters,
            topicTerms: topicTerms,
            contentMode: contentMode,
            config: config
        )

        let candidates = generated.candidates
            .sorted {
                if $0.productSelectionScore != $1.productSelectionScore {
                    return $0.productSelectionScore > $1.productSelectionScore
                }
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
            let leftScore = min(100, max(0, $0.candidate.productSelectionScore + $0.diversityBonus))
            let rightScore = min(100, max(0, $1.candidate.productSelectionScore + $1.diversityBonus))
            if leftScore != rightScore { return leftScore > rightScore }
            if $0.candidate.productSelectionScore != $1.candidate.productSelectionScore {
                return $0.candidate.productSelectionScore > $1.candidate.productSelectionScore
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

    public static func rankQuery(
        result: SenseResult,
        query: String,
        config: MomentRankerConfig = MomentRankerConfig()
    ) -> QueryMomentRankingResult {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedQuery = parseMomentQuery(trimmedQuery) else {
            return QueryMomentRankingResult(
                sourceTitle: result.title,
                sourceURL: result.url,
                query: trimmedQuery,
                queryStrength: .weak,
                noResultReason: "empty_query",
                rankedMoments: [],
                queryCandidates: config.includeCandidates ? [] : nil,
                rejectedQueryAnchors: config.includeCandidates ? [] : nil,
                dedupedOverlaps: config.includeCandidates ? [] : nil
            )
        }

        let blocks = result.transcriptBlocks
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startSeconds < $1.startSeconds }

        guard !blocks.isEmpty else {
            return QueryMomentRankingResult(
                sourceTitle: result.title,
                sourceURL: result.url,
                query: trimmedQuery,
                queryStrength: .weak,
                noResultReason: "no_transcript_blocks",
                rankedMoments: [],
                queryCandidates: config.includeCandidates ? [] : nil,
                rejectedQueryAnchors: config.includeCandidates ? [] : nil,
                dedupedOverlaps: config.includeCandidates ? [] : nil
            )
        }

        let metadataTopicTerms = extractKeywords(
            ([result.title, result.description ?? ""] + result.tags + result.chapters.map(\.title))
                .joined(separator: " ")
        )
        let topicTerms = metadataTopicTerms.union(dominantTranscriptTerms(blocks))
        let contentMode = detectContentMode(result: result, blocks: blocks)

        let generated = generateQueryCandidates(
            blocks: blocks,
            chapters: result.chapters,
            sourceURL: result.url,
            parsedQuery: parsedQuery,
            topicTerms: topicTerms,
            contentMode: contentMode,
            config: queryMomentConfig(from: config)
        )

        let sortedCandidates = generated.candidates.sorted {
            if $0.combinedScore != $1.combinedScore { return $0.combinedScore > $1.combinedScore }
            if $0.queryMatch.score != $1.queryMatch.score { return $0.queryMatch.score > $1.queryMatch.score }
            return $0.candidate.startSeconds < $1.candidate.startSeconds
        }

        let debugCandidates = sortedCandidates
            .prefix(config.maxCandidateCount)
            .enumerated()
            .map { idx, candidate in
                candidate.asMoment(rank: idx + 1, idPrefix: "qc", diversityBonus: 0)
            }

        let selected = selectQueryMoments(
            candidates: sortedCandidates,
            limit: config.limit
        )

        let rankedMoments = selected.selected.enumerated().map { idx, selectedCandidate in
            selectedCandidate.candidate.asMoment(
                rank: idx + 1,
                idPrefix: "q",
                diversityBonus: selectedCandidate.diversityBonus,
                extraWhy: selectedCandidate.diversityBonus >= 6 ? ["distinct from other query matches"] : []
            )
        }

        let noResultReason: String?
        if rankedMoments.isEmpty {
            if generated.sawQueryMatch {
                noResultReason = "no_useful_query_moment"
            } else {
                noResultReason = "no_query_match"
            }
        } else {
            noResultReason = nil
        }

        return QueryMomentRankingResult(
            sourceTitle: result.title,
            sourceURL: result.url,
            query: trimmedQuery,
            queryStrength: rankedMoments.isEmpty ? .weak : aggregateQueryStrength(rankedMoments),
            noResultReason: noResultReason,
            rankedMoments: rankedMoments,
            queryCandidates: config.includeCandidates ? Array(debugCandidates) : nil,
            rejectedQueryAnchors: config.includeCandidates ? generated.rejectedAnchors : nil,
            dedupedOverlaps: config.includeCandidates ? selected.dedupedOverlaps : nil
        )
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
    let contentMode: ContentMode
    let wouldUserClickScore: Int
    let clickScoreRaw: Int
    let scoreCapApplied: Bool
    let scoreCapReason: String?
    let usefulnessSignals: [String]
    let modeSpecificBoosts: [String]
    let modeSpecificPenalties: [String]
    let sponsorDetected: Bool
    let selectedForProduct: Bool

    var durationSeconds: Double { endSeconds - startSeconds }
    var baseScore: Int { min(85, max(0, breakdown.baseScore)) }
    var productSelectionScore: Int { wouldUserClickScore }

    func asMoment(
        rank: Int,
        idPrefix: String,
        mmrDiversity: Int,
        extraWhy: [String] = []
    ) -> RankedMoment {
        let finalBreakdown = breakdown.withMMRDiversity(mmrDiversity)
        return RankedMoment(
            id: "\(idPrefix)\(rank)",
            rank: rank,
            startSeconds: roundTime(startSeconds),
            endSeconds: roundTime(endSeconds),
            durationSeconds: roundTime(durationSeconds),
            titleHint: titleHint,
            cleanText: cleanText,
            score: wouldUserClickScore,
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
            productWorthinessSignals: productWorthinessSignals.isEmpty ? nil : productWorthinessSignals,
            contentMode: contentMode.rawValue,
            wouldUserClickScore: wouldUserClickScore,
            clickScoreRaw: clickScoreRaw,
            clickScoreFinal: wouldUserClickScore,
            scoreCapApplied: scoreCapApplied,
            scoreCapReason: scoreCapReason,
            usefulnessSignals: usefulnessSignals.isEmpty ? nil : usefulnessSignals,
            modeSpecificBoosts: modeSpecificBoosts.isEmpty ? nil : modeSpecificBoosts,
            modeSpecificPenalties: modeSpecificPenalties.isEmpty ? nil : modeSpecificPenalties,
            sponsorDetected: sponsorDetected,
            selectedForProduct: selectedForProduct
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

private struct PayoffAnchor {
    let text: String
    let score: Int
    let breakdown: MomentAnchorBreakdown
    let topicAlignment: Int
    let chapterSpecificity: Double
    let numberIsTopicAligned: Bool
    let hasConsequenceNearby: Bool
    let productWorthinessSignals: [String]
}

private struct ParsedMomentQuery {
    let raw: String
    let normalized: String
    let terms: [String]
    let termVariants: [String: Set<String>]
    let phrases: [String]
}

private struct QueryMatchEvaluation {
    let score: Int
    let matchedTerms: [String]
    let exactPhrase: Bool
    let allTermsMatched: Bool
    let proximity: Int?
    let reasons: [String]
}

private struct QueryIntentEvaluation {
    let score: Int
    let signals: [String]
    let reasons: [String]
}

private struct QueryMomentCandidate {
    let candidate: MomentCandidate
    let queryMatch: QueryMatchEvaluation
    let queryIntent: QueryIntentEvaluation
    let momentQualityScore: Int
    let boundaryQualityScore: Int
    let combinedScore: Int
    let queryStrength: QueryMomentStrength
    let videoURLAtTime: String?
    let queryEvidence: QueryEvidence?

    func asMoment(
        rank: Int,
        idPrefix: String,
        diversityBonus: Int,
        extraWhy: [String] = []
    ) -> RankedMoment {
        let diversity = max(0, min(10, diversityBonus))
        let finalCombined = min(100, max(0, combinedScore + diversity))
        let finalBreakdown = candidate.breakdown.withMMRDiversity(diversity)
        let queryBreakdown = QueryMomentScoreBreakdown(
            queryMatch: queryMatch.score,
            queryIntent: queryIntent.score,
            momentQuality: momentQualityScore,
            boundaryQuality: boundaryQualityScore,
            diversity: diversity,
            combined: finalCombined
        )
        let queryWhy = queryMatch.reasons
            + queryIntent.reasons
            + (boundaryQualityScore >= 70 ? ["clean query moment boundaries"] : [])
            + (momentQualityScore >= 70 ? ["strong moment quality around query"] : [])

        return RankedMoment(
            id: "\(idPrefix)\(rank)",
            rank: rank,
            startSeconds: roundTime(candidate.startSeconds),
            endSeconds: roundTime(candidate.endSeconds),
            durationSeconds: roundTime(candidate.durationSeconds),
            titleHint: candidate.titleHint,
            cleanText: candidate.cleanText,
            score: finalCombined,
            candidateType: candidate.candidateType,
            confidence: roundConfidence(Double(finalCombined) / 100.0),
            chapterTitle: candidate.chapterTitle,
            chapterIndex: candidate.chapterIndex,
            scoreBreakdown: finalBreakdown,
            whySelected: Array((queryWhy + candidate.why + extraWhy).prefix(7)),
            centerSentence: candidate.centerSentence,
            anchorScore: candidate.anchorScore,
            anchorBreakdown: candidate.anchorBreakdown,
            topicAlignment: candidate.topicAlignment,
            chapterSpecificity: candidate.chapterSpecificity.map(roundConfidence),
            numberIsTopicAligned: candidate.numberIsTopicAligned,
            hasConsequenceNearby: candidate.hasConsequenceNearby,
            anchorRejected: candidate.anchorRejected,
            rejectionReason: candidate.rejectionReason,
            productWorthinessSignals: candidate.productWorthinessSignals.isEmpty ? nil : candidate.productWorthinessSignals,
            contentMode: candidate.contentMode.rawValue,
            wouldUserClickScore: momentQualityScore,
            clickScoreRaw: candidate.clickScoreRaw,
            clickScoreFinal: momentQualityScore,
            scoreCapApplied: candidate.scoreCapApplied,
            scoreCapReason: candidate.scoreCapReason,
            usefulnessSignals: candidate.usefulnessSignals.isEmpty ? nil : candidate.usefulnessSignals,
            modeSpecificBoosts: candidate.modeSpecificBoosts.isEmpty ? nil : candidate.modeSpecificBoosts,
            modeSpecificPenalties: candidate.modeSpecificPenalties.isEmpty ? nil : candidate.modeSpecificPenalties,
            sponsorDetected: candidate.sponsorDetected,
            selectedForProduct: queryStrength != .weak && finalCombined >= 65 && rank <= 5,
            queryStrength: queryStrength.rawValue,
            matchedTerms: queryMatch.matchedTerms,
            queryMatchScore: queryMatch.score,
            queryIntentScore: queryIntent.score,
            queryIntentSignals: queryIntent.signals.isEmpty ? nil : queryIntent.signals,
            momentQualityScore: momentQualityScore,
            boundaryQualityScore: boundaryQualityScore,
            combinedScore: finalCombined,
            queryScoreBreakdown: queryBreakdown,
            videoURLAtTime: videoURLAtTime,
            queryEvidence: queryEvidence
        )
    }
}

private struct QueryCandidateGenerationResult {
    let candidates: [QueryMomentCandidate]
    let rejectedAnchors: [RejectedQueryAnchor]
    let sawQueryMatch: Bool
}

private struct SelectedQueryCandidate {
    let candidate: QueryMomentCandidate
    let diversityBonus: Int
}

private struct QuerySelectionResult {
    let selected: [SelectedQueryCandidate]
    let dedupedOverlaps: [DedupedQueryOverlap]
}

private struct CandidateGenerationResult {
    let candidates: [MomentCandidate]
    let rejectedAnchors: [RejectedMomentAnchor]
}

private enum ContentMode: String, Sendable, Equatable {
    case tutorialHowTo = "tutorial/how-to"
    case podcastInterview = "podcast/interview"
    case newsRoundup = "news/roundup"
    case documentary
    case productExplainer = "product/explainer"
    case unknown
}

private struct ProductEvaluation {
    let rawScore: Int
    let finalScore: Int
    let scoreCapApplied: Bool
    let scoreCapReason: String?
    let usefulnessSignals: [String]
    let modeSpecificBoosts: [String]
    let modeSpecificPenalties: [String]
    let sponsorDetected: Bool
    let selectedForProduct: Bool
}

private func detectContentMode(result: SenseResult, blocks: [TranscriptBlock]) -> ContentMode {
    let metadata = ([result.title, result.description ?? ""] + result.tags + result.chapters.map(\.title))
        .joined(separator: " ")
        .lowercased()
    let sample = blocks.prefix(140).map(\.text).joined(separator: " ").lowercased()
    let combined = "\(metadata) \(sample)"

    var scores: [ContentMode: Int] = [:]
    func add(_ mode: ContentMode, _ points: Int) {
        scores[mode, default: 0] += points
    }
    func hits(_ phrases: [String], in text: String = combined) -> Int {
        phrases.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
    }

    add(.tutorialHowTo, hits(["tutorial", "course", "beginner", "full course", "how to", "step by step", "walkthrough"], in: metadata) * 8)
    add(.tutorialHowTo, hits(["click", "open", "install", "create", "set up", "debug", "test the app", "run the command"], in: sample) * 2)

    add(.podcastInterview, hits(["podcast", "interview", "guest", "founder", "my first million", "lex fridman", "startup ideas"], in: metadata) * 8)
    add(.podcastInterview, hits(["thanks for coming", "thanks for having me", "on the show", "talk about", "tell me about"], in: sample) * 3)

    add(.newsRoundup, hits(["news", "daily", "roundup", "today", "latest", "updates", "launches", "released"], in: metadata) * 7)
    add(.newsRoundup, hits(["all right, more", "more on", "story", "headline", "breaking", "market cap"], in: sample) * 3)

    add(.documentary, hits(["documentary", "frontline", "nova", "pbs", "tribeca", "full documentary", "film festival"], in: metadata) * 10)
    add(.documentary, hits(["[music]", "narrator", "in those days", "lifetime", "history"], in: sample) * 3)

    add(.productExplainer, hits(["explained", "what is", "clearly explained", "demo", "product", "api", "framework", "agent", "tool"], in: metadata) * 6)
    add(.productExplainer, hits(["this tool", "this product", "the api", "lets you", "allows you", "you can use"], in: sample) * 3)

    let ranked = scores.sorted {
        if $0.value != $1.value { return $0.value > $1.value }
        return $0.key.rawValue < $1.key.rawValue
    }
    guard let best = ranked.first, best.value >= 8 else { return .unknown }
    return best.key
}

private func evaluateProductQuality(
    text: String,
    centerSentence: String?,
    contentMode: ContentMode,
    baseScore: Int,
    productWorthinessSignals: [String],
    topicAlignment: Int,
    numberIsTopicAligned: Bool?,
    hasConsequenceNearby: Bool,
    concretenessScore: Int,
    insightScore: Int,
    selfContainedScore: Int,
    anchorScore: Int?,
    chapterTitle: String?,
    startSeconds: Double
) -> ProductEvaluation {
    let lower = text.lowercased()
    let centerText = centerSentence ?? text
    let center = centerText.lowercased()
    var score = min(56, max(22, baseScore))
    var usefulness = Set<String>()
    var boosts: [String] = []
    var penalties: [String] = []

    func boost(_ signal: String, _ points: Int) {
        usefulness.insert(signal)
        score += points
    }
    func modeBoost(_ signal: String, _ points: Int) {
        boosts.append(signal)
        score += points
    }
    func penalty(_ signal: String, _ points: Int) {
        penalties.append(signal)
        score -= points
    }

    if hasConsequenceNearby || lower.contains("this means") || lower.contains("why it matters") {
        boost("clear_consequence", 9)
    }
    if lower.contains("because") || lower.contains("therefore") || lower.contains("as a result") || lower.contains("which is why") {
        boost("causal_explanation", 8)
    }
    if lower.contains("instead of") || lower.contains("rather than") || lower.contains("tradeoff") || lower.contains("but actually") {
        boost("decision_or_tradeoff", 8)
    }
    if lower.contains("mistake") || lower.contains("lesson") || lower.contains("learned") || lower.contains("the key") {
        boost("explicit_lesson", 8)
    }
    if lower.contains("turns out") || lower.contains("surprising") || lower.contains("counterintuitive") || lower.contains("weird") {
        boost("surprising_claim", 8)
    }
    if lower.contains("before") && lower.contains("now") || lower.contains("used to") && lower.contains("now") {
        boost("before_after", 7)
    }
    if numberIsTopicAligned == true {
        boost("topic_aligned_metric", hasConsequenceNearby ? 10 : 5)
    }
    if topicAlignment >= 8 {
        boost("strong_topic_alignment", 4)
    }
    if selfContainedScore >= 10 {
        boost("self_contained", 3)
    }

    let actionable = hasActionableInstruction(lower)
    if actionable {
        boost("actionable_instruction", 7)
    }

    let sponsorDetected = hasSponsorOrShoutout(text)
    if sponsorDetected {
        penalty("sponsor_or_shoutout", 70)
    }
    if isInterviewerSetup(center) || isInterviewerSetup(String(lower.prefix(240))) {
        penalty("interviewer_setup", 48)
    }
    if hasPodcastMetaFluff(lower) || hasCreatorMetaHook(lower) {
        penalty("creator_or_podcast_meta", 45)
    }
    if isVagueActionRule(center, concretenessScore: concretenessScore, topicAlignment: topicAlignment) {
        penalty("vague_actionable_rule", 30)
    }
    if startsWithDanglingHook(center), concretenessScore < 10, topicAlignment < 6 {
        penalty("dangling_context", 22)
    }
    if containsNarrationArtifact(lower) {
        penalty("caption_or_music_artifact", 18)
    }
    if hasProcessWithoutPayoff(lower, usefulnessSignals: usefulness) {
        penalty("process_without_payoff", 18)
    }
    if isNamedroppingWithoutLesson(lower, usefulnessSignals: usefulness) {
        penalty("namedropping_without_lesson", 14)
    }
    if hasNumberWithoutPayoff(lower, numberIsTopicAligned: numberIsTopicAligned, usefulnessSignals: usefulness) {
        penalty("number_without_payoff", 15)
    }
    if isIntroOrRecapOnly(lower, chapterTitle: chapterTitle, startSeconds: startSeconds) {
        penalty("intro_or_recap", 18)
    }
    if isWeakCenterSentence(center, concretenessScore: concretenessScore, topicAlignment: topicAlignment) {
        penalty("weak_center_sentence", 18)
    }

    switch contentMode {
    case .tutorialHowTo:
        if actionable { modeBoost("tutorial_actionable_step", 16) }
        if lower.contains("common mistake") || lower.contains("if this fails") || lower.contains("fix") || lower.contains("debug") {
            modeBoost("tutorial_failure_or_fix", 12)
        }
        if isTutorialMeta(lower) {
            penalty("tutorial_meta_overview", 34)
        }
        if isToolDescriptionWithoutAction(lower), !actionable {
            penalty("tool_description_without_action", 18)
        }
    case .podcastInterview:
        if lower.contains("lesson") || lower.contains("mistake") || lower.contains("what i learned") || lower.contains("the key") {
            modeBoost("podcast_lesson", 12)
        }
        if lower.contains("decided") || lower.contains("changed") || lower.contains("realized") {
            modeBoost("podcast_decision_or_change", 10)
        }
        if isRandomAnecdoteWithoutLesson(lower, usefulnessSignals: usefulness) {
            penalty("podcast_anecdote_without_lesson", 18)
        }
    case .newsRoundup:
        if lower.contains("impact") || lower.contains("market") || lower.contains("policy") || lower.contains("company") || lower.contains("because") {
            modeBoost("news_consequence", 12)
        }
        if isIsolatedNewsFact(lower, usefulnessSignals: usefulness) {
            penalty("isolated_news_fact", 22)
        }
    case .documentary:
        if lower.contains("this was") || lower.contains("that was") || lower.contains("because") || lower.contains("discovered") || lower.contains("realized") {
            modeBoost("documentary_turning_point", 11)
        }
        if isDocumentarySceneSetting(lower, usefulnessSignals: usefulness) {
            penalty("documentary_scene_fragment", 22)
        }
    case .productExplainer:
        if lower.contains("lets you") || lower.contains("allows you") || lower.contains("now you can") || lower.contains("makes it possible") {
            modeBoost("product_capability", 12)
        }
        if lower.contains("why this matters") || lower.contains("what is") || lower.contains("this means") {
            modeBoost("product_explanation", 8)
        }
    case .unknown:
        break
    }

    let hasPayoff = hasActualPayoff(usefulnessSignals: usefulness, lower: lower, productSignals: productWorthinessSignals)
    if !hasPayoff {
        penalty("no_actual_payoff", 22)
    }

    let rawScore = min(100, max(0, score))
    let cap = clickScoreCap(
        text: text,
        centerSentence: centerText,
        rawScore: rawScore,
        contentMode: contentMode,
        usefulnessSignals: usefulness,
        productSignals: productWorthinessSignals,
        topicAlignment: topicAlignment,
        hasConsequenceNearby: hasConsequenceNearby,
        anchorScore: anchorScore,
        sponsorDetected: sponsorDetected
    )

    let hardBlocked = sponsorDetected
        || penalties.contains("interviewer_setup")
        || penalties.contains("creator_or_podcast_meta")
        || penalties.contains("vague_actionable_rule")
        || penalties.contains("caption_or_music_artifact")
    let finalScore = min(rawScore, cap.maxScore)
    let weakTopicAlignment = topicAlignment == 0 && finalScore < 85
    let selected = finalScore >= 75 && hasPayoff && !hardBlocked && !weakTopicAlignment

    return ProductEvaluation(
        rawScore: rawScore,
        finalScore: finalScore,
        scoreCapApplied: finalScore < rawScore,
        scoreCapReason: finalScore < rawScore ? cap.reason : nil,
        usefulnessSignals: Array(usefulness).sorted(),
        modeSpecificBoosts: Array(Set(boosts)).sorted(),
        modeSpecificPenalties: Array(Set(penalties)).sorted(),
        sponsorDetected: sponsorDetected,
        selectedForProduct: selected
    )
}

private func generateCandidates(
    blocks: [TranscriptBlock],
    chapters: [VideoChapter],
    topicTerms: Set<String>,
    contentMode: ContentMode,
    config: MomentRankerConfig
) -> CandidateGenerationResult {
    let anchorCandidates = generateAnchorCandidates(
        blocks: blocks,
        chapters: chapters,
        topicTerms: topicTerms,
        contentMode: contentMode,
        config: config
    )

    if anchorCandidates.candidates.filter(\.selectedForProduct).count >= min(config.limit, 4) {
        return anchorCandidates
    }

    let fallbackCandidates = generateWindowCandidates(
        blocks: blocks,
        chapters: chapters,
        topicTerms: topicTerms,
        contentMode: contentMode,
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
    contentMode: ContentMode,
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
            contentMode: contentMode,
            config: config
        )
    }
}

private func generateAnchorCandidates(
    blocks: [TranscriptBlock],
    chapters: [VideoChapter],
    topicTerms: Set<String>,
    contentMode: ContentMode,
    config: MomentRankerConfig
) -> CandidateGenerationResult {
    let units = buildImpactUnits(
        blocks: blocks,
        chapters: chapters,
        topicTerms: topicTerms,
        contentMode: contentMode
    )
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
            contentMode: contentMode,
            config: config
        ) else { continue }
        candidates.append(candidate)
    }

    return CandidateGenerationResult(
        candidates: candidates,
        rejectedAnchors: Array(rejectedAnchors.prefix(config.maxCandidateCount))
    )
}

private func queryMomentConfig(from config: MomentRankerConfig) -> MomentRankerConfig {
    MomentRankerConfig(
        limit: config.limit,
        includeCandidates: config.includeCandidates,
        minDurationSeconds: min(config.minDurationSeconds, 18.0),
        targetDurationSeconds: min(config.targetDurationSeconds, 42.0),
        maxDurationSeconds: min(config.maxDurationSeconds, 58.0),
        strideSeconds: config.strideSeconds,
        qualityThreshold: max(20, config.qualityThreshold - 12),
        maxCandidateCount: max(config.maxCandidateCount, max(50, config.limit * 10))
    )
}

private func generateQueryCandidates(
    blocks: [TranscriptBlock],
    chapters: [VideoChapter],
    sourceURL: String,
    parsedQuery: ParsedMomentQuery,
    topicTerms: Set<String>,
    contentMode: ContentMode,
    config: MomentRankerConfig
) -> QueryCandidateGenerationResult {
    let units = buildImpactUnits(
        blocks: blocks,
        chapters: chapters,
        topicTerms: topicTerms,
        contentMode: contentMode
    )
    guard !units.isEmpty else {
        return QueryCandidateGenerationResult(candidates: [], rejectedAnchors: [], sawQueryMatch: false)
    }

    let scoredAnchors = units.compactMap { unit -> (unit: ImpactUnit, match: QueryMatchEvaluation)? in
        let chapterTitle = unit.chapterIndex.flatMap { chapters.indices.contains($0) ? chapters[$0].title : nil }
        let match = evaluateQueryMatch(text: unit.text, chapterTitle: chapterTitle, parsedQuery: parsedQuery)
        guard match.score > 0 else { return nil }
        return (unit, match)
    }
    let sawQueryMatch = !scoredAnchors.isEmpty

    let anchorBudget = min(scoredAnchors.count, max(50, config.limit * 12))
    let anchors = scoredAnchors
        .sorted {
            if $0.match.score != $1.match.score { return $0.match.score > $1.match.score }
            if $0.unit.anchorScore != $1.unit.anchorScore { return $0.unit.anchorScore > $1.unit.anchorScore }
            return $0.unit.startSeconds < $1.unit.startSeconds
        }
        .prefix(anchorBudget)

    var candidates: [QueryMomentCandidate] = []
    var rejectedAnchors: [RejectedQueryAnchor] = []

    for item in anchors {
        let anchor = item.unit
        let match = item.match
        let chapterTitle = anchor.chapterIndex.flatMap { chapters.indices.contains($0) ? chapters[$0].title : nil }

        if let reason = queryAnchorHardRejection(anchor.text, chapterTitle: chapterTitle) {
            rejectedAnchors.append(
                rejectedQueryAnchor(
                    anchor,
                    match: match,
                    chapters: chapters,
                    id: "qr\(rejectedAnchors.count + 1)",
                    reason: reason
                )
            )
            continue
        }

        let range = expandAnchorWindow(
            units: units,
            anchorIndex: anchor.index,
            config: config
        )
        let built = makeQueryCandidate(
            units: units,
            range: range,
            anchor: anchor,
            anchorMatch: match,
            chapters: chapters,
            sourceURL: sourceURL,
            parsedQuery: parsedQuery,
            topicTerms: topicTerms,
            contentMode: contentMode,
            config: config
        )

        if let candidate = built.candidate {
            candidates.append(candidate)
        } else {
            rejectedAnchors.append(
                rejectedQueryAnchor(
                    anchor,
                    match: match,
                    chapters: chapters,
                    id: "qr\(rejectedAnchors.count + 1)",
                    reason: built.rejectionReason ?? "weak_or_dirty_query_window"
                )
            )
        }
    }

    return QueryCandidateGenerationResult(
        candidates: candidates,
        rejectedAnchors: Array(rejectedAnchors.prefix(config.maxCandidateCount)),
        sawQueryMatch: sawQueryMatch
    )
}

private func makeQueryCandidate(
    units: [ImpactUnit],
    range: ClosedRange<Int>,
    anchor: ImpactUnit,
    anchorMatch: QueryMatchEvaluation,
    chapters: [VideoChapter],
    sourceURL: String,
    parsedQuery: ParsedMomentQuery,
    topicTerms: Set<String>,
    contentMode: ContentMode,
    config: MomentRankerConfig
) -> (candidate: QueryMomentCandidate?, rejectionReason: String?) {
    let startIndex = max(0, range.lowerBound)
    let endIndex = min(units.count - 1, range.upperBound)
    guard startIndex <= endIndex else { return (nil, "invalid_query_window") }

    var windowUnits = trimPromotionalLeadInUnits(
        Array(units[startIndex ... endIndex]),
        anchorIndex: anchor.index
    )
    windowUnits = trimDirtyLeadInUnits(
        windowUnits,
        anchorIndex: anchor.index
    )
    guard windowUnits.first != nil, windowUnits.last != nil else {
        return (nil, "empty_query_window")
    }

    var rawText = stitchTextSegments(windowUnits.map(\.text))
    var text = finalizeMomentText(rawText)
    guard !text.isEmpty else { return (nil, "empty_query_text") }

    var words = wordCount(text)
    guard words >= 10 else { return (nil, "weak_transcript_fragment") }

    let chapterContext = resolveChapterContext(
        startSeconds: anchor.startSeconds,
        preferredIndex: anchor.chapterIndex,
        chapters: chapters
    )
    let chapterIndex = chapterContext.index
    let chapterTitle = chapterContext.title
    var lower = text.lowercased()

    if let reason = queryAnchorHardRejection(text, chapterTitle: chapterTitle) {
        return (nil, reason)
    }
    guard !isHardRejectedLeadIn(text: rawText.lowercased(), chapterTitle: chapterTitle),
          !isHardRejectedLeadIn(text: lower, chapterTitle: chapterTitle) else {
        return (nil, "sponsor_or_admin_meta")
    }

    var windowMatch = evaluateQueryMatch(text: text, chapterTitle: chapterTitle, parsedQuery: parsedQuery)
    var queryMatch = windowMatch.score >= anchorMatch.score ? windowMatch : anchorMatch
    guard queryMatch.score > 0 else { return (nil, "window_lost_query_match") }

    var center = bestQueryCenter(
        in: text,
        fallback: anchor.text,
        chapterTitle: chapterTitle,
        parsedQuery: parsedQuery,
        topicTerms: topicTerms,
        contentMode: contentMode
    )
    if queryCenterNeedsPreviousContext(center.text),
       let currentFirst = windowUnits.first,
       currentFirst.index > 0 {
        let previous = units[currentFirst.index - 1]
        let currentLast = windowUnits.last ?? currentFirst
        let gap = max(0.0, currentFirst.startSeconds - previous.endSeconds)
        let repairedDuration = currentLast.endSeconds - previous.startSeconds
        if gap <= 4.0,
           repairedDuration <= anchorMaxDuration(config),
           !contextBlockLooksPromotional(previous.text),
           !hasSponsorOrShoutout(previous.text) {
            windowUnits.insert(previous, at: 0)
            rawText = stitchTextSegments(windowUnits.map(\.text))
            text = finalizeMomentText(rawText)
            words = wordCount(text)
            lower = text.lowercased()
            windowMatch = evaluateQueryMatch(text: text, chapterTitle: chapterTitle, parsedQuery: parsedQuery)
            queryMatch = windowMatch.score >= anchorMatch.score ? windowMatch : anchorMatch
            center = bestQueryCenter(
                in: text,
                fallback: anchor.text,
                chapterTitle: chapterTitle,
                parsedQuery: parsedQuery,
                topicTerms: topicTerms,
                contentMode: contentMode
            )
        }
    }

    let centerSentence = center.text
    if isInterviewerSetup(centerSentence.lowercased()) {
        return (nil, "interviewer_setup")
    }
    guard let first = windowUnits.first, let last = windowUnits.last else {
        return (nil, "empty_query_window")
    }
    let queryIntent = queryIntentEvaluation(
        text: text,
        centerSentence: centerSentence,
        parsedQuery: parsedQuery,
        queryMatch: queryMatch,
        anchorEvaluation: center.evaluation
    )
    let effectiveQueryMatch = queryMatchWithIntentBoost(queryMatch, intent: queryIntent)
    let floor = queryMatchFloor(parsedQuery)
    guard queryMatch.score >= floor else {
        return (nil, "below_query_floor")
    }

    let keywords = extractKeywords(text)
    let topicScore = topicRelevanceScore(keywords: keywords, topicTerms: topicTerms)
    let hasNumber = lower.range(of: #"\d"#, options: .regularExpression) != nil
    let numberAligned = hasNumber && isNumberTopicAligned(
        text: text,
        topicTerms: topicTerms.union(Set(parsedQuery.terms)),
        chapterTitle: chapterTitle
    )
    let hasConsequence = hasConsequenceLanguage(lower)
    let insight = min(28, max(insightScore(lower), max(0, center.evaluation.breakdown.score / 2)))
    var concrete = max(concretenessScore(lower), center.evaluation.breakdown.concrete)
    if hasNumber, !numberAligned {
        concrete = Int((Double(concrete) * 0.4).rounded(.down))
    }
    if hasNumber, !hasConsequence {
        concrete = Int((Double(concrete) * 0.65).rounded(.down))
    }
    concrete = min(30, concrete)

    let selfContained = selfContainedScore(text: text, wordCount: words)
    let specificity = chapterSpecificityScore(chapterTitle)
    let rawChapterScore = chapterScore(
        chapterTitle: chapterTitle,
        chapterIndex: chapterIndex,
        firstStart: first.startSeconds,
        chapters: chapters
    )
    let chapterScore = min(14, max(0, Int((Double(rawChapterScore) * specificity).rounded())))
    let quality = qualityPenalty(
        text: lower,
        wordCount: words,
        chapterTitle: chapterTitle,
        startSeconds: first.startSeconds
    )

    let productSignals = deriveProductWorthinessSignals(
        text: text,
        breakdown: center.evaluation.breakdown,
        hasNumber: hasNumber,
        numberIsTopicAligned: numberAligned,
        hasConsequenceNearby: hasConsequence || center.evaluation.hasConsequenceNearby
    )

    let breakdown = MomentScoreBreakdown(
        topicRelevance: topicScore,
        insight: insight,
        concreteness: concrete,
        selfContained: selfContained,
        chapter: chapterScore,
        qualityPenalty: quality
    )
    let base = min(85, max(0, breakdown.baseScore))
    let productEvaluation = evaluateProductQuality(
        text: text,
        centerSentence: centerSentence,
        contentMode: contentMode,
        baseScore: max(22, base),
        productWorthinessSignals: productSignals,
        topicAlignment: max(topicScore, center.evaluation.topicAlignment),
        numberIsTopicAligned: hasNumber ? numberAligned : nil,
        hasConsequenceNearby: hasConsequence || center.evaluation.hasConsequenceNearby,
        concretenessScore: concrete,
        insightScore: insight,
        selfContainedScore: selfContained,
        anchorScore: max(0, center.evaluation.breakdown.score),
        chapterTitle: chapterTitle,
        startSeconds: first.startSeconds
    )

    if productEvaluation.sponsorDetected || hasSponsorOrShoutout(text) {
        return (nil, "sponsor_or_cta")
    }
    if productEvaluation.modeSpecificPenalties.contains("creator_or_podcast_meta")
        || hasPodcastMetaFluff(lower)
        || hasCreatorMetaHook(lower) {
        return (nil, "sponsor_or_admin_meta")
    }
    if containsNarrationArtifact(lower), queryMatch.score < 80 {
        return (nil, "caption_or_music_artifact")
    }

    var boundaryQuality = queryBoundaryQuality(
        text: text,
        wordCount: words,
        selfContainedScore: selfContained
    )
    let centerRamblePenalty = queryRamblingPenalty(centerSentence)
    let unresolvedQueryContext = queryCenterNeedsPreviousContext(centerSentence)
        && text.hasPrefix(centerSentence)
    if unresolvedQueryContext {
        boundaryQuality = min(boundaryQuality, 58)
    }
    let mentionOnlyPenalty = queryMentionOnlyPenalty(
        queryMatch: queryMatch,
        intent: queryIntent,
        productSignals: productSignals,
        centerSentence: centerSentence
    )
    var momentQuality = queryMomentQuality(
        productEvaluation: productEvaluation,
        queryMatch: effectiveQueryMatch,
        insightScore: insight,
        concreteScore: concrete,
        selfContainedScore: selfContained,
        qualityPenalty: quality,
        productSignals: productSignals
    )
    momentQuality = min(100, max(0, momentQuality + min(12, queryIntent.score / 2) - centerRamblePenalty - mentionOnlyPenalty))
    let weakFragment = words < 18 || startsLikelyIncomplete(text) || endsLikelyIncomplete(text)
    var combined = combinedQueryScore(
        queryMatch: effectiveQueryMatch.score,
        momentQuality: momentQuality,
        boundaryQuality: boundaryQuality,
        diversity: 0
    )
    if weakFragment { combined = min(combined, 60) }
    if queryMatch.score < floor { combined = min(combined, 58) }
    if momentQuality < 45 { combined = min(combined, 70) }
    if centerRamblePenalty >= 30 { combined = min(combined, 62) }
    if unresolvedQueryContext { combined = min(combined, 64) }

    guard combined >= 45 else { return (nil, "weak_query_match") }

    let type = candidateType(
        insight: insight,
        concreteness: concrete,
        chapter: chapterScore,
        lower: lower
    )
    let why = whySelected(
        topicScore: topicScore,
        insightScore: insight,
        concreteScore: concrete,
        selfContained: selfContained,
        chapterScore: chapterScore,
        qualityPenalty: quality
    )
    var strength = queryStrength(
        combinedScore: combined,
        queryMatch: effectiveQueryMatch,
        momentQuality: momentQuality,
        boundaryQuality: boundaryQuality
    )
    if centerRamblePenalty >= 30 {
        strength = .weak
    }
    if unresolvedQueryContext {
        strength = .weak
    }

    let moment = MomentCandidate(
        startSeconds: first.startSeconds,
        endSeconds: last.endSeconds,
        titleHint: titleHint(text: text, chapterTitle: chapterTitle, candidateType: type),
        cleanText: text,
        candidateType: type,
        confidence: Double(combined) / 100.0,
        chapterTitle: chapterTitle,
        chapterIndex: chapterIndex,
        breakdown: breakdown,
        keywords: keywords.union(Set(queryMatch.matchedTerms)),
        why: why,
        centerSentence: centerSentence,
        anchorScore: max(0, center.evaluation.breakdown.score),
        anchorBreakdown: center.evaluation.breakdown,
        topicAlignment: max(topicScore, center.evaluation.topicAlignment),
        chapterSpecificity: max(specificity, center.evaluation.chapterSpecificity),
        numberIsTopicAligned: hasNumber ? numberAligned : nil,
        hasConsequenceNearby: hasConsequence || center.evaluation.hasConsequenceNearby,
        anchorRejected: false,
        rejectionReason: nil,
        productWorthinessSignals: productSignals,
        contentMode: contentMode,
        wouldUserClickScore: momentQuality,
        clickScoreRaw: productEvaluation.rawScore,
        scoreCapApplied: productEvaluation.scoreCapApplied,
        scoreCapReason: productEvaluation.scoreCapReason,
        usefulnessSignals: productEvaluation.usefulnessSignals,
        modeSpecificBoosts: productEvaluation.modeSpecificBoosts,
        modeSpecificPenalties: productEvaluation.modeSpecificPenalties,
        sponsorDetected: productEvaluation.sponsorDetected,
        selectedForProduct: strength != .weak && combined >= 75
    )

    let evidence = buildQueryEvidence(
        contextText: text,
        centerSentence: centerSentence,
        windowUnits: windowUnits,
        parsedQuery: parsedQuery,
        queryMatch: effectiveQueryMatch,
        sourceURL: sourceURL
    )

    return (
        QueryMomentCandidate(
            candidate: moment,
            queryMatch: effectiveQueryMatch,
            queryIntent: queryIntent,
            momentQualityScore: momentQuality,
            boundaryQualityScore: boundaryQuality,
            combinedScore: combined,
            queryStrength: strength,
            videoURLAtTime: evidence?.urlAtMatch ?? videoURLAtTime(sourceURL: sourceURL, startSeconds: first.startSeconds),
            queryEvidence: evidence
        ),
        nil
    )
}

private func bestQueryCenter(
    in text: String,
    fallback: String,
    chapterTitle: String?,
    parsedQuery: ParsedMomentQuery,
    topicTerms: Set<String>,
    contentMode: ContentMode
) -> (text: String, evaluation: AnchorEvaluation, match: QueryMatchEvaluation) {
    let sentences = sentenceRanges(in: text)
        .map { finalizeAnchorText(String(text[$0])) }
        .filter { wordCount($0) >= 4 }

    var best: (text: String, evaluation: AnchorEvaluation, match: QueryMatchEvaluation, score: Int)?
    for sentence in sentences {
        let match = evaluateQueryMatch(text: sentence, chapterTitle: chapterTitle, parsedQuery: parsedQuery)
        let evaluation = anchorEvaluation(
            text: sentence,
            chapterTitle: chapterTitle,
            topicTerms: topicTerms.union(Set(parsedQuery.terms)),
            contentMode: contentMode
        )
        let intent = queryIntentEvaluation(
            text: sentence,
            centerSentence: sentence,
            parsedQuery: parsedQuery,
            queryMatch: match,
            anchorEvaluation: evaluation
        )
        var score = match.score * 3 + max(0, evaluation.breakdown.score)
        score += intent.score * 2
        score -= queryRamblingPenalty(sentence)
        if evaluation.rejectionReason == nil { score += 12 } else { score -= 22 }
        if isQuestionAnchor(sentence) { score -= 28 }
        if startsLikelyIncomplete(sentence) { score -= 14 }
        if hasConsequenceLanguage(sentence.lowercased()) { score += 10 }
        if queryCenterNeedsPreviousContext(sentence) { score -= 8 }
        if score > (best?.score ?? Int.min) {
            best = (sentence, evaluation, match, score)
        }
    }

    if let best {
        return (
            capitalizeMomentStart(best.text),
            best.evaluation,
            best.match
        )
    }

    let fallbackText = capitalizeMomentStart(finalizeAnchorText(fallback))
    let fallbackEvaluation = anchorEvaluation(
        text: fallbackText,
        chapterTitle: chapterTitle,
        topicTerms: topicTerms.union(Set(parsedQuery.terms)),
        contentMode: contentMode
    )
    return (
        fallbackText,
        fallbackEvaluation,
        evaluateQueryMatch(text: fallbackText, chapterTitle: chapterTitle, parsedQuery: parsedQuery)
    )
}

private func buildQueryEvidence(
    contextText: String,
    centerSentence: String,
    windowUnits: [ImpactUnit],
    parsedQuery: ParsedMomentQuery,
    queryMatch: QueryMatchEvaluation,
    sourceURL: String
) -> QueryEvidence? {
    let sentence = cleanTranscript(centerSentence)
    guard !sentence.isEmpty,
          let timingUnit = bestQueryTimingUnit(
            in: windowUnits,
            centerSentence: sentence,
            parsedQuery: parsedQuery
          ) else {
        return nil
    }

    let sentenceMatch = evaluateQueryMatch(
        text: sentence,
        chapterTitle: nil,
        parsedQuery: parsedQuery
    )
    let evidenceMatch = sentenceMatch.score >= queryMatch.score ? sentenceMatch : queryMatch
    let matchedTerms = evidenceMatch.matchedTerms.isEmpty
        ? queryMatch.matchedTerms
        : evidenceMatch.matchedTerms
    let highlights = queryHighlightRanges(
        in: sentence,
        parsedQuery: parsedQuery,
        matchedTerms: matchedTerms
    )

    return QueryEvidence(
        displayTitle: queryDisplayTitle(
            matchSentence: sentence,
            contextText: contextText,
            parsedQuery: parsedQuery,
            matchedTerms: matchedTerms,
            matchStartSeconds: timingUnit.startSeconds
        ),
        matchSentence: sentence,
        matchStartSeconds: roundTime(timingUnit.startSeconds),
        matchEndSeconds: roundTime(timingUnit.endSeconds),
        matchedTerms: matchedTerms,
        highlightRanges: highlights,
        contextText: contextText,
        urlAtMatch: videoURLAtTime(sourceURL: sourceURL, startSeconds: timingUnit.startSeconds),
        queryMatchScore: evidenceMatch.score
    )
}

private func bestQueryTimingUnit(
    in windowUnits: [ImpactUnit],
    centerSentence: String,
    parsedQuery: ParsedMomentQuery
) -> ImpactUnit? {
    guard !windowUnits.isEmpty else { return nil }

    let normalizedCenter = normalizedSearchPhrase(centerSentence)
    if !normalizedCenter.isEmpty {
        if let containing = windowUnits.first(where: {
            let unitPhrase = normalizedSearchPhrase($0.text)
            return unitPhrase.contains(normalizedCenter) || normalizedCenter.contains(unitPhrase)
        }) {
            return containing
        }
    }

    return windowUnits.max {
        let lhs = evaluateQueryMatch(text: $0.text, chapterTitle: nil, parsedQuery: parsedQuery)
        let rhs = evaluateQueryMatch(text: $1.text, chapterTitle: nil, parsedQuery: parsedQuery)
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        return $0.startSeconds > $1.startSeconds
    }
}

private func queryDisplayTitle(
    matchSentence: String,
    contextText: String,
    parsedQuery: ParsedMomentQuery,
    matchedTerms: [String],
    matchStartSeconds: Double
) -> String {
    let sentence = cleanTranscript(matchSentence)
    if let numericTitle = numericQueryTitle(
        in: sentence,
        parsedQuery: parsedQuery,
        matchedTerms: matchedTerms
    ) {
        return numericTitle
    }

    if let entityTitle = entityComparisonTitle(
        matchSentence: sentence,
        contextText: contextText
    ) {
        return entityTitle
    }

    if let contextTitle = contextTopicTitle(
        contextText: contextText,
        matchSentence: sentence
    ) {
        return contextTitle
    }

    let clauses = sentence
        .components(separatedBy: CharacterSet(charactersIn: ",;:"))
        .map(trimQueryTitlePrefix)
        .filter {
            isTrustworthyQueryTitle(
                $0,
                parsedQuery: parsedQuery,
                matchedTerms: matchedTerms
            )
        }

    let candidates = clauses.isEmpty ? [trimQueryTitlePrefix(sentence)] : clauses
    let best = candidates.max { lhs, rhs in
        queryTitleScore(lhs, parsedQuery: parsedQuery, matchedTerms: matchedTerms)
            < queryTitleScore(rhs, parsedQuery: parsedQuery, matchedTerms: matchedTerms)
    } ?? sentence

    if isTrustworthyQueryTitle(
        best,
        parsedQuery: parsedQuery,
        matchedTerms: matchedTerms
    ) {
        return truncateQueryTitle(best)
    }

    return transcriptMatchTitle(startSeconds: matchStartSeconds)
}

private func numericQueryTitle(
    in sentence: String,
    parsedQuery: ParsedMomentQuery,
    matchedTerms: [String]
) -> String? {
    let terms = matchedTerms.isEmpty ? parsedQuery.terms : matchedTerms
    let lowerTerms = Set(terms.map { $0.lowercased() })
    let wantsMillion = lowerTerms.contains("million") || sentence.lowercased().contains("million")

    let patterns: [String]
    if wantsMillion {
        patterns = [
            #"\$[0-9][0-9.,]*(?:\s+(?:per|each|a))?\s+million(?:\s+[A-Za-z][A-Za-z0-9-]*){0,3}"#,
            #"\b[0-9][0-9.,]*(?:\s+[0-9][0-9.,]*)?\s+million(?:\s+[A-Za-z][A-Za-z0-9-]*){0,3}"#
        ]
    } else {
        patterns = [
            #"\$[0-9][0-9.,]*(?:\s+[A-Za-z][A-Za-z0-9-]*){0,4}"#,
            #"\b[0-9][0-9.,]*%?(?:\s+[A-Za-z][A-Za-z0-9-]*){0,4}"#
        ]
    }

    for pattern in patterns {
        let matches = regexMatches(pattern, in: sentence)
        for match in matches {
            let title = truncateQueryTitle(trimQueryTitleAtStopword(match))
            guard isTrustworthyQueryTitle(
                title,
                parsedQuery: parsedQuery,
                matchedTerms: matchedTerms
            ) else { continue }
        let titleMatch = evaluateQueryMatch(text: title, chapterTitle: nil, parsedQuery: parsedQuery)
        if titleMatch.score > 0 || title.lowercased().contains("million") {
            return title
        }
        }
    }

    return nil
}

private func regexMatches(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(
        pattern: pattern,
        options: [.caseInsensitive]
    ) else { return [] }

    let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
    return regex.matches(in: text, range: nsRange).compactMap { match in
        guard let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }
}

private func trimQueryTitleAtStopword(_ text: String) -> String {
    let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
    let stopwords = Set(["and", "but", "because", "when", "if", "that", "which", "so"])
    guard let stopIndex = words.firstIndex(where: { stopwords.contains(normalizedToken($0)) }),
          stopIndex >= 3 else {
        return cleanTranscript(text)
    }
    return cleanTranscript(words[..<stopIndex].joined(separator: " "))
}

private func entityComparisonTitle(matchSentence: String, contextText: String) -> String? {
    let pattern = #"^([A-Z][A-Za-z0-9-]*(?:\s+[A-Z][A-Za-z0-9-]*){0,2})\b.*?\band\s+([A-Z][A-Za-z0-9-]*(?:\s+[A-Z][A-Za-z0-9-]*){0,2})\s+(?:has|had|have|with|was|is)\b"#
    guard let entities = firstCapturedGroups(pattern, in: matchSentence),
          entities.count >= 2,
          let first = cleanEntityName(entities[0]),
          let second = cleanEntityName(entities[1]),
          first != second else {
        return nil
    }

    let lowerContext = contextText.lowercased()
    let descriptor: String
    if lowerContext.contains("exchange") {
        descriptor = "exchange counts"
    } else if lowerContext.contains("distillation") {
        descriptor = "distillation scale"
    } else if lowerContext.contains("benchmark") || lowerContext.contains("scale") || lowerContext.contains("comparison") {
        descriptor = "scale comparison"
    } else {
        descriptor = "comparison"
    }

    return "\(first) and \(second) \(descriptor)"
}

private func contextTopicTitle(contextText: String, matchSentence: String) -> String? {
    let normalizedMatch = normalizedSearchPhrase(matchSentence)
    let candidates = sentenceRanges(in: contextText)
        .map { cleanTranscript(String(contextText[$0])) }
        .filter { sentence in
            let normalized = normalizedSearchPhrase(sentence)
            return !normalized.isEmpty
                && normalized != normalizedMatch
                && wordCount(sentence) >= 5
                && !isLowTrustContextTitle(sentence)
        }

    guard let best = candidates.max(by: {
        contextTitleScore($0) < contextTitleScore($1)
    }), contextTitleScore(best) >= 18 else {
        return nil
    }

    let title = conceptualTitle(from: best)
    return isLowTrustContextTitle(title) ? nil : truncateQueryTitle(title)
}

private func contextTitleScore(_ sentence: String) -> Int {
    let lower = sentence.lowercased()
    var score = 0
    if lower.contains("scale") { score += 12 }
    if lower.contains("distillation") { score += 12 }
    if lower.contains("benchmark") { score += 10 }
    if lower.contains("report") { score += 8 }
    if lower.contains("exchange") { score += 8 }
    if lower.contains("comparison") || lower.contains("competitor") { score += 6 }
    score += min(12, namedEntityCount(in: sentence) * 3)
    if lower.range(of: #"\d"#, options: .regularExpression) != nil { score += 3 }
    if lower.hasPrefix("all right") || lower.hasPrefix("i just") { score -= 12 }
    score -= max(0, wordCount(sentence) - 18)
    return score
}

private func conceptualTitle(from sentence: String) -> String {
    let cleaned = trimQueryTitlePrefix(sentence)
    let patterns = [
        #"\s+is\s+(?:just|only|about|roughly|around)?\s*[\$0-9]"#,
        #"\s+are\s+(?:just|only|about|roughly|around)?\s*[\$0-9]"#,
        #"\s+was\s+(?:just|only|about|roughly|around)?\s*[\$0-9]"#
    ]
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            continue
        }
        let nsRange = NSRange(cleaned.startIndex ..< cleaned.endIndex, in: cleaned)
        guard let match = regex.firstMatch(in: cleaned, range: nsRange),
              let range = Range(match.range, in: cleaned) else {
            continue
        }
        let prefix = cleanTranscript(String(cleaned[..<range.lowerBound]))
        if wordCount(prefix) >= 4 { return prefix }
    }
    return cleaned
}

private func isLowTrustContextTitle(_ title: String) -> Bool {
    let lower = title.lowercased()
    if wordCount(title) < 4 { return true }
    if lower.hasPrefix("maybe ") || lower.hasPrefix("all right") || lower.hasPrefix("i just") {
        return true
    }
    if hasMalformedNumericTitle(title) { return true }
    return false
}

private func queryTitleScore(
    _ title: String,
    parsedQuery: ParsedMomentQuery,
    matchedTerms: [String]
) -> Int {
    let match = evaluateQueryMatch(text: title, chapterTitle: nil, parsedQuery: parsedQuery)
    let lower = title.lowercased()
    var score = match.score * 10
    if lower.range(of: #"\d"#, options: .regularExpression) != nil { score += 30 }
    if lower.contains("$") || lower.contains("percent") || lower.contains("million") || lower.contains("billion") {
        score += 20
    }
    let titleTokens = Set(searchTokens(title))
    for term in matchedTerms {
        if titleTokens.contains(stemSearchToken(term)) { score += 8 }
    }
    score -= max(0, wordCount(title) - 14)
    return score
}

private func isTrustworthyQueryTitle(
    _ title: String,
    parsedQuery: ParsedMomentQuery,
    matchedTerms: [String]
) -> Bool {
    let cleaned = stripTrailingSentencePunctuation(cleanTranscript(title))
    let words = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
    guard words.count >= 4 else { return false }
    if hasMalformedNumericTitle(cleaned) { return false }

    let queryTerms = Set((matchedTerms.isEmpty ? parsedQuery.terms : matchedTerms).map(stemSearchToken))
    let lowInfo = Set([
        "a", "an", "the", "and", "or", "but", "per", "each", "million", "billion",
        "percent"
    ])

    var contentCount = 0
    var hasEntity = false
    for word in words {
        let normalized = normalizedToken(word)
        let stem = stemSearchToken(word)
        let hasDigit = normalized.range(of: #"\d"#, options: .regularExpression) != nil
        if word.first?.isUppercase == true, !hasDigit {
            hasEntity = true
        }
        if hasDigit || queryTerms.contains(stem) || lowInfo.contains(stem) || lowInfo.contains(normalized) {
            continue
        }
        contentCount += 1
    }

    if cleaned.contains("$"), contentCount >= 2 { return true }
    return hasEntity || contentCount >= 2
}

private func hasMalformedNumericTitle(_ title: String) -> Bool {
    let patterns = [
        #"\b\d+(?:\.\d+)?\s+\d+(?:\.\d+)?\s+(?:million|billion|thousand)\b"#,
        #"\b(\d+(?:\.\d+)?)\s+\1\s+(?:million|billion|thousand)\b"#
    ]
    return patterns.contains { pattern in
        title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

private func firstCapturedGroups(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }
    let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: nsRange), match.numberOfRanges > 1 else {
        return nil
    }
    return (1 ..< match.numberOfRanges).compactMap { index in
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}

private func cleanEntityName(_ raw: String) -> String? {
    let name = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted.union(.whitespacesAndNewlines))
    guard !name.isEmpty else { return nil }
    let blocked = Set(["I", "You", "You're", "This", "That", "All", "Maybe", "Imagine"])
    if blocked.contains(name) { return nil }
    return name
}

private func namedEntityCount(in text: String) -> Int {
    let blocked = Set(["I", "You", "This", "That", "All", "Maybe", "Imagine"])
    return text
        .split(whereSeparator: \.isWhitespace)
        .map { String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
        .filter { !$0.isEmpty && $0.first?.isUppercase == true && !blocked.contains($0) }
        .count
}

private func transcriptMatchTitle(startSeconds: Double) -> String {
    "Transcript match at \(clockTime(startSeconds))"
}

private func clockTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

private func trimQueryTitlePrefix(_ text: String) -> String {
    var value = cleanTranscript(text)
    let prefixes = [
        "and ", "but ", "so ", "because ", "which means ", "this means ",
        "that means ", "it means ", "then ", "now "
    ]
    var changed = true
    while changed {
        changed = false
        let lower = value.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            changed = true
            break
        }
    }
    return value
}

private func truncateQueryTitle(_ text: String) -> String {
    let value = cleanTranscript(text)
    guard value.count > 110 else {
        return stripTrailingSentencePunctuation(value)
    }

    var words: [Substring] = []
    var count = 0
    for word in value.split(whereSeparator: \.isWhitespace) {
        let nextCount = count + word.count + (words.isEmpty ? 0 : 1)
        if nextCount > 104 { break }
        words.append(word)
        count = nextCount
    }
    let truncated = words.isEmpty ? String(value.prefix(104)) : words.joined(separator: " ")
    return stripTrailingSentencePunctuation(truncated) + "..."
}

private func stripTrailingSentencePunctuation(_ text: String) -> String {
    text.trimmingCharacters(in: CharacterSet(charactersIn: ".?! "))
}

private func queryHighlightRanges(
    in sentence: String,
    parsedQuery: ParsedMomentQuery,
    matchedTerms: [String]
) -> [QueryHighlightRange] {
    let terms = matchedTerms.isEmpty ? parsedQuery.terms : matchedTerms
    let termSet = Set(terms)
    var ranges: [QueryHighlightRange] = []

    var index = sentence.startIndex
    while index < sentence.endIndex {
        guard isAlphanumeric(sentence[index]) else {
            index = sentence.index(after: index)
            continue
        }

        let start = index
        var end = index
        while end < sentence.endIndex, isAlphanumeric(sentence[end]) {
            end = sentence.index(after: end)
        }

        let token = String(sentence[start ..< end])
        let stemmed = stemSearchToken(token)
        let matchingTerm = terms.first { term in
            let variants = parsedQuery.termVariants[term] ?? [term]
            return variants.contains(stemmed) || variants.contains(normalizedToken(token))
        }

        if let matchingTerm, termSet.contains(matchingTerm) {
            ranges.append(QueryHighlightRange(
                start: sentence.distance(from: sentence.startIndex, to: start),
                end: sentence.distance(from: sentence.startIndex, to: end),
                term: matchingTerm
            ))
        }

        index = end
    }

    return ranges
}

private func isAlphanumeric(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
}

private func queryAnchorHardRejection(_ text: String, chapterTitle: String?) -> String? {
    let lower = text.lowercased()
    if hasSponsorOrShoutout(text) || contextBlockLooksPromotional(text) {
        return "sponsor_or_cta"
    }
    if hasPodcastMetaFluff(lower) || hasCreatorMetaHook(lower) || isAdChapterTitle(chapterTitle?.lowercased()) {
        return "sponsor_or_admin_meta"
    }
    return nil
}

private func rejectedQueryAnchor(
    _ anchor: ImpactUnit,
    match: QueryMatchEvaluation,
    chapters: [VideoChapter],
    id: String,
    reason: String
) -> RejectedQueryAnchor {
    let chapterContext = resolveChapterContext(
        startSeconds: anchor.startSeconds,
        preferredIndex: anchor.chapterIndex,
        chapters: chapters
    )
    return RejectedQueryAnchor(
        id: id,
        startSeconds: roundTime(anchor.startSeconds),
        endSeconds: roundTime(anchor.endSeconds),
        centerSentence: capitalizeMomentStart(finalizeAnchorText(anchor.text)),
        chapterTitle: chapterContext.title,
        chapterIndex: chapterContext.index,
        queryMatchScore: match.score,
        matchedTerms: match.matchedTerms,
        rejectionReason: reason
    )
}

private func buildImpactUnits(
    blocks: [TranscriptBlock],
    chapters: [VideoChapter],
    topicTerms: Set<String>,
    contentMode: ContentMode
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
            topicTerms: topicTerms,
            contentMode: contentMode
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
    topicTerms: Set<String>,
    contentMode: ContentMode
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
    if contentMode == .tutorialHowTo {
        if isProcessSetupAnchor(lower) || isTutorialMeta(lower) {
            processPenalty = -12
        } else if processHits >= 2, !hasActionableInstruction(lower), !hasConsequenceNearby {
            processPenalty = -8
        } else {
            processPenalty = 0
        }
    } else if processHits >= 2 {
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
    if hasSponsorOrShoutout(text) { anchorQualityPenalty -= 45 }
    if isInterviewerSetup(lower) { anchorQualityPenalty -= 30 }
    if hasPodcastMetaFluff(lower) { anchorQualityPenalty -= 34 }
    if isQuestionAnchor(text) { anchorQualityPenalty -= 20 }
    if endsWithDanglingPhrase(text) { anchorQualityPenalty -= 25 }
    if isProcessSetupAnchor(lower), contentMode != .tutorialHowTo { anchorQualityPenalty -= 18 }
    if isRandomAnecdoteAnchor(lower) { anchorQualityPenalty -= 16 }
    if hasDanglingPronounStart(text) { anchorQualityPenalty -= 5 }
    if isVagueActionRule(lower, concretenessScore: concrete, topicAlignment: topic) {
        anchorQualityPenalty -= 25
    }

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

private func bestPayoffAnchor(
    in text: String,
    chapterTitle: String?,
    topicTerms: Set<String>,
    contentMode: ContentMode
) -> PayoffAnchor? {
    sentenceRanges(in: text)
        .compactMap { range -> PayoffAnchor? in
            let sentence = finalizeAnchorText(String(text[range]))
            guard wordCount(sentence) >= 4 else { return nil }
            let evaluation = anchorEvaluation(
                text: sentence,
                chapterTitle: chapterTitle,
                topicTerms: topicTerms,
                contentMode: contentMode
            )
            guard evaluation.rejectionReason == nil else { return nil }
            let score = max(0, evaluation.breakdown.score)
            guard score > 0 else { return nil }
            return PayoffAnchor(
                text: capitalizeMomentStart(sentence),
                score: score,
                breakdown: evaluation.breakdown,
                topicAlignment: evaluation.topicAlignment,
                chapterSpecificity: evaluation.chapterSpecificity,
                numberIsTopicAligned: evaluation.numberIsTopicAligned,
                hasConsequenceNearby: evaluation.hasConsequenceNearby,
                productWorthinessSignals: evaluation.productWorthinessSignals
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.topicAlignment != $1.topicAlignment { return $0.topicAlignment > $1.topicAlignment }
            return $0.text.count > $1.text.count
        }
        .first
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
    if first == "this",
       let second = tokens.dropFirst().first,
       ["means", "lets", "allows", "creates", "turns"].contains(second) {
        return false
    }
    let danglingStarts: Set<String> = ["it", "they", "he", "she", "this", "that", "these", "those", "most"]
    guard danglingStarts.contains(first) else { return false }

    let hasNumber = tokens.contains { $0.range(of: #"\d"#, options: .regularExpression) != nil }
    let hasNamedSubjectCue = tokens.contains {
        ["model", "company", "companies", "product", "users", "customers", "team", "founders", "workflow", "agent", "agents"].contains($0)
    }
    return !hasNumber && !hasNamedSubjectCue
}

private func containsAny(_ lower: String, _ phrases: [String]) -> Bool {
    phrases.contains(where: lower.contains)
}

private func hasActionableInstruction(_ lower: String) -> Bool {
    if containsAny(lower, ["shouldn't", "should not", "don't need to", "doesn't need to"]) {
        return false
    }

    if lower.range(
        of: #"\b(click|open|install|run|copy|paste|create|enable|disable|debug|test|deploy|compile|select|drag|drop|resize|move|delete|add|change|compare|check|ask|write|build|remove)\b"#,
        options: .regularExpression
    ) != nil {
        return true
    }

    if lower.range(
        of: #"\b(go to|set up|turn on|pull up|start a new|create a new|run evals|common mistake|if this fails|do this)\b"#,
        options: .regularExpression
    ) != nil {
        return true
    }

    return lower.range(
        of: #"\b(?:you|we|i)\s+(?:should|need to|have to|want to|can)\s+(?:click|open|run|copy|paste|create|enable|disable|test|debug|deploy|use|ask|start|stop|compare|check|write|build|remove|add|change)\b"#,
        options: .regularExpression
    ) != nil
}

private func hasSponsorOrShoutout(_ text: String) -> Bool {
    let lower = text.lowercased()
    if hasNativeAdRead(text) { return true }
    return containsAny(
        lower,
        [
            "supporting sponsor", "sponsor", "sponsored", "brought to you by",
            "use code", "promo code", "check out", "learn more at", "link below",
            "in the description", "description below", "subscribe", "sent us",
            "box of goodies", "green tea", "ingredients", "dream team", "hubspot",
            "supervibe", "vanta.com", "workos.com", "works.com", "as a listener",
            "try it risk-free", "risk-free for 30 days", "abundant mines",
            "own your machines", "bitcoin you mine", "i've partnered with",
            "link in the", "hit subscribe"
        ]
    )
}

private func hasNativeAdRead(_ text: String) -> Bool {
    let lower = text.lowercased()
    if lower.range(of: #"\bi'?ve partnered with\b"#, options: .regularExpression) != nil { return true }
    if lower.range(of: #"\bin just \d+ (days|weeks|months),? i('?ve| have) seen\b"#, options: .regularExpression) != nil {
        return true
    }
    if lower.range(of: #"\bthey ran \d+ biomarkers\b"#, options: .regularExpression) != nil { return true }

    let brandPatterns = [
        #"\b[Tt]he reason,\s+[A-Z][A-Za-z0-9&'\-]{2,}\b"#,
        #"\b[Cc]heck out\s+[A-Z][A-Za-z0-9&'\-]{2,}\b"#,
        #"\b[Ll]ink in the\s+(description|show notes|comments)\b"#
    ]
    return brandPatterns.contains { pattern in
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

private func isInterviewerSetup(_ lower: String) -> Bool {
    let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
    let triggers = [
        "talk about", "tell me about", "i'm curious", "you mentioned",
        "let's talk about", "walk me through", "explain to me", "i want to ask",
        "i wanted to ask", "can you talk", "what are the biggest", "how do you think",
        "i'd love to hear", "help me understand"
    ]
    return triggers.contains { trigger in
        trimmed.hasPrefix(trigger) || trimmed.contains(" \(trigger)")
    }
}

private func hasPodcastMetaFluff(_ lower: String) -> Bool {
    containsAny(
        lower,
        [
            "this podcast", "this episode", "my guest", "on the show",
            "thanks for having me", "thanks for coming", "listen to this",
            "startup ideas podcast", "before we start", "before we get started",
            "the keynote", "my talk", "the speaker after me", "in this session",
            "keynote after me", "talk after me", "see the keynote"
        ]
    )
}

private func hasCreatorMetaHook(_ lower: String) -> Bool {
    containsAny(
        lower,
        [
            "by the end of the episode", "by the end of this video",
            "by the end of this episode", "let's get into it", "lets get into it",
            "go to this talk", "hit subscribe", "smash subscribe",
            "like and subscribe", "before we dive in", "without further ado"
        ]
    )
}

private func hasConcreteSubjectCue(_ lower: String) -> Bool {
    if lower.range(of: #"\d"#, options: .regularExpression) != nil { return true }
    return containsAny(
        lower,
        [
            "model", "company", "customer", "customers", "user", "users",
            "revenue", "cost", "price", "workflow", "agent", "agents", "api",
            "product", "market", "policy", "system", "benchmark", "eval",
            "tests", "security", "bitcoin", "cursor", "deepseek", "firecrawl",
            "dataset", "server", "founder", "team", "automation"
        ]
    )
}

private func isVagueActionRule(
    _ lower: String,
    concretenessScore: Int,
    topicAlignment: Int
) -> Bool {
    let actionCue = containsAny(lower, ["have to", "has to", "need to", "should", "must"])
    guard actionCue else { return false }

    let vagueCue = containsAny(
        lower,
        ["something", "stuff", "things", "kind of", "sort of", "like something", "this thing"]
    )
    return vagueCue
        && concretenessScore < 10
        && topicAlignment < 6
        && !hasConcreteSubjectCue(lower)
}

private func startsWithDanglingHook(_ lower: String) -> Bool {
    let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("this means ")
        || trimmed.hasPrefix("this is why ")
        || trimmed.hasPrefix("this lets ")
        || trimmed.hasPrefix("this allows ")
        || trimmed.hasPrefix("this creates ")
        || trimmed.hasPrefix("this turns ") {
        return false
    }
    let prefixes = [
        "he ", "she ", "it ", "they ", "this ", "that ", "these ", "those ",
        "the man who ", "the guy who ", "the person who ", "most "
    ]
    return prefixes.contains(where: trimmed.hasPrefix)
}

private func containsNarrationArtifact(_ lower: String) -> Bool {
    containsAny(lower, ["[music]", "(music)", "[applause]", "(applause)", "♪"])
}

private func hasProcessWithoutPayoff(_ lower: String, usefulnessSignals: Set<String>) -> Bool {
    let processHits = countMatches(
        lower,
        phrases: ["first", "then", "next", "step", "setup", "download", "install", "open the"]
    )
    guard processHits >= 2 else { return false }
    return usefulnessSignals.isDisjoint(with: ["clear_consequence", "actionable_instruction", "causal_explanation"])
}

private func isNamedroppingWithoutLesson(_ lower: String, usefulnessSignals: Set<String>) -> Bool {
    guard usefulnessSignals.isDisjoint(with: ["explicit_lesson", "clear_consequence", "decision_or_tradeoff"]) else {
        return false
    }
    let nameDropCues = ["my friend", "i met", "i talked to", "he invited", "she invited", "cfo of", "ceo of"]
    return containsAny(lower, nameDropCues)
}

private func hasNumberWithoutPayoff(
    _ lower: String,
    numberIsTopicAligned: Bool?,
    usefulnessSignals: Set<String>
) -> Bool {
    guard lower.range(of: #"\d"#, options: .regularExpression) != nil else { return false }
    if numberIsTopicAligned == true { return false }
    return usefulnessSignals.isDisjoint(with: [
        "clear_consequence", "causal_explanation", "decision_or_tradeoff",
        "topic_aligned_metric", "surprising_claim"
    ])
}

private func isIntroOrRecapOnly(
    _ lower: String,
    chapterTitle: String?,
    startSeconds: Double
) -> Bool {
    let chapter = chapterTitle?.lowercased() ?? ""
    let introContext = startSeconds < 150 || isIntroChapterTitle(chapter)
    guard introContext else { return false }
    return containsAny(
        lower,
        [
            "welcome back", "today we're going to", "today we are going to",
            "in this video", "we're going to cover", "we will cover",
            "before we get into", "quick recap", "what we covered"
        ]
    )
}

private func isTutorialMeta(_ lower: String) -> Bool {
    containsAny(
        lower,
        [
            "we will cover", "we're going to cover", "in this course",
            "in this section", "getting started", "before we", "this is cursor",
            "cursor 2.0", "super fun for me", "we're currently in"
        ]
    )
}

private func isToolDescriptionWithoutAction(_ lower: String) -> Bool {
    containsAny(
        lower,
        ["this is a tool", "this tool allows", "allows you to", "lets you", "new cursor 2.0"]
    ) && !hasActionableInstruction(lower)
}

private func isRandomAnecdoteWithoutLesson(_ lower: String, usefulnessSignals: Set<String>) -> Bool {
    guard usefulnessSignals.isDisjoint(with: ["explicit_lesson", "clear_consequence", "causal_explanation"]) else {
        return false
    }
    return containsAny(
        lower,
        ["i was like", "my friend", "we went", "invited me", "i met", "i heard in", "one time"]
    )
}

private func isIsolatedNewsFact(_ lower: String, usefulnessSignals: Set<String>) -> Bool {
    guard usefulnessSignals.isDisjoint(with: ["clear_consequence", "causal_explanation", "decision_or_tradeoff"]) else {
        return false
    }
    return containsAny(
        lower,
        ["more on this later", "all right, more", "one weird story", "ufo", "missing scientists"]
    )
}

private func isDocumentarySceneSetting(_ lower: String, usefulnessSignals: Set<String>) -> Bool {
    if containsNarrationArtifact(lower) { return true }
    guard usefulnessSignals.isDisjoint(with: ["causal_explanation", "clear_consequence", "surprising_claim"]) else {
        return false
    }
    return containsAny(lower, ["in those days", "years earlier", "at the time", "was born", "grew up"])
}

private func isWeakCenterSentence(
    _ lower: String,
    concretenessScore: Int,
    topicAlignment: Int
) -> Bool {
    let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
    let weakPrefixes = [
        "that's actually really good", "it might be", "i don't want", "i first met",
        "try it risk-free", "you can come back", "the results were not very good",
        "i said", "i gave", "yes, it looks", "we started generalizing"
    ]
    if weakPrefixes.contains(where: trimmed.hasPrefix),
       concretenessScore < 14 || topicAlignment < 6 {
        return true
    }

    if wordCount(trimmed) <= 7,
       concretenessScore < 14,
       !containsAny(trimmed, ["because", "therefore", "this means", "the key", "mistake"]) {
        return true
    }

    return false
}

private struct ClickScoreCap {
    let maxScore: Int
    let reason: String?
}

private func clickScoreCap(
    text: String,
    centerSentence: String,
    rawScore: Int,
    contentMode: ContentMode,
    usefulnessSignals: Set<String>,
    productSignals: [String],
    topicAlignment: Int,
    hasConsequenceNearby: Bool,
    anchorScore: Int?,
    sponsorDetected: Bool
) -> ClickScoreCap {
    var cap = 100
    var reasons: [String] = []

    func apply(_ maxScore: Int, _ reason: String) {
        if maxScore < cap { cap = maxScore }
        reasons.append(reason)
    }

    let lower = text.lowercased()
    let center = centerSentence.lowercased()
    let veryStrongPayoff = usefulnessSignals.contains("explicit_lesson")
        || usefulnessSignals.contains("clear_consequence") && usefulnessSignals.contains("causal_explanation")
        || Set(productSignals).contains("topic_aligned_number")

    if center.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || anchorScore == nil {
        apply(70, "missingPayoffAnchor")
    }
    if centerHasTranscriptArtifact(centerSentence) {
        apply(68, "transcriptArtifactCenter")
    }
    if startsLikelyIncomplete(centerSentence) || hasMalformedPayoffStart(centerSentence) {
        apply(74, "incompletePayoffCenter")
    }
    if isOverlongPayoffCenter(centerSentence) {
        apply(88, "overlongPayoffCenter")
    }
    if isSoftOpinionCenter(center), !veryStrongPayoff {
        apply(88, "softOpinionCenter")
    }
    if let anchorScore, anchorScore < 10 {
        apply(65, "anchorScoreBelow10")
    }
    if topicAlignment == 0, !veryStrongPayoff {
        apply(70, "topicAlignmentZero")
    }
    if !hasConsequenceNearby {
        apply(75, "noConsequenceNearby")
    }
    if isSetupOrMetaCenter(center) || isWeakCenterSentence(center, concretenessScore: 0, topicAlignment: topicAlignment) {
        apply(60, "setupOrMetaCenter")
    }
    if sponsorDetected || hasSponsorOrShoutout(text) {
        apply(40, "sponsorOrAdVibe")
    }
    if hasCreatorMetaHook(lower) || hasPodcastMetaFluff(lower) {
        apply(55, "creatorOrPodcastMeta")
    }
    if containsNarrationArtifact(lower) {
        apply(45, "captionOrMusicArtifact")
    }
    if hasDirtyOpeningSentence(text) {
        apply(72, "dirtyLeadIn")
    }

    switch contentMode {
    case .tutorialHowTo:
        if isTutorialMeta(lower) || isToolDescriptionWithoutAction(lower) {
            apply(65, "tutorialMetaOrToolDescription")
        }
    case .podcastInterview:
        if isPodcastBanterOrBio(lower, usefulnessSignals: usefulnessSignals) {
            apply(65, "podcastBanterOrBio")
        }
    case .documentary:
        if isDocumentarySceneSetting(lower, usefulnessSignals: usefulnessSignals) {
            apply(65, "documentarySceneSetting")
        }
    case .newsRoundup:
        if isIsolatedNewsFact(lower, usefulnessSignals: usefulnessSignals) {
            apply(65, "isolatedNewsFact")
        }
    case .productExplainer, .unknown:
        break
    }

    if rawScore < 90 {
        cap = min(cap, 89)
        if rawScore >= 75 { reasons.append("rawScoreBelowMustWatch") }
    }

    return ClickScoreCap(
        maxScore: cap,
        reason: reasons.isEmpty ? nil : Array(Set(reasons)).sorted().joined(separator: ",")
    )
}

private func isSetupOrMetaCenter(_ lower: String) -> Bool {
    containsAny(
        lower,
        [
            "let's get into it", "by the end of", "we're going to", "we are going to",
            "i want to talk about", "i want to ask", "this episode", "this video",
            "go to this talk", "you were going to say", "thoughts on this"
        ]
    )
}

private func centerHasTranscriptArtifact(_ centerSentence: String) -> Bool {
    let lower = centerSentence.lowercased()
    return containsAny(lower, ["[music]", "[applause]", "[laughter]", "(music)", "\\h", "♪"])
}

private func hasMalformedPayoffStart(_ centerSentence: String) -> Bool {
    let trimmed = centerSentence.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ "))
    let lower = stripped.lowercased()

    if stripped.isEmpty { return true }
    if lower.hasPrefix("um,")
        || lower.hasPrefix("uh,")
        || lower.hasPrefix("yeah,")
        || lower.hasPrefix("and ")
        || lower.hasPrefix("but ")
        || lower.hasPrefix("so ")
        || lower.hasPrefix("because ") {
        return true
    }
    if stripped.range(of: #"^\d+(?:\.\d+)?\s+(?:as|and|but|because|so|um|uh)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
        return true
    }
    if let first = stripped.unicodeScalars.first,
       CharacterSet.lowercaseLetters.contains(first) {
        return true
    }
    if let first = stripped.first,
       ["-", ",", ";", ":", ")", "]"].contains(first) {
        return true
    }
    return false
}

private func isOverlongPayoffCenter(_ centerSentence: String) -> Bool {
    wordCount(centerSentence) > 36
}

private func isSoftOpinionCenter(_ lower: String) -> Bool {
    let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasPrefix("i think ")
        || trimmed.hasPrefix("i just think ")
        || trimmed.hasPrefix("i mean ")
        || trimmed.hasPrefix("i would ")
        || trimmed.hasPrefix("i'm not saying ")
        || trimmed.hasPrefix("im not saying ")
}

private func isPodcastBanterOrBio(_ lower: String, usefulnessSignals: Set<String>) -> Bool {
    guard usefulnessSignals.isDisjoint(with: ["explicit_lesson", "decision_or_tradeoff", "clear_consequence"]) else {
        return false
    }
    return containsAny(
        lower,
        [
            "fun hang", "shockingly fun", "great guy", "great guest", "my friend",
            "i first met", "grew up", "went to college", "biography", "backstory"
        ]
    )
}

private func hasActualPayoff(
    usefulnessSignals: Set<String>,
    lower: String,
    productSignals: [String]
) -> Bool {
    let strongUsefulness: Set<String> = [
        "actionable_instruction", "clear_consequence", "surprising_claim",
        "explicit_lesson", "causal_explanation", "decision_or_tradeoff",
        "topic_aligned_metric", "before_after"
    ]
    if !usefulnessSignals.isDisjoint(with: strongUsefulness) { return true }

    let strongProductSignals: Set<String> = [
        "strong_contrast", "decision_point", "surprising_claim",
        "topic_aligned_number", "topic_aligned_concrete_evidence"
    ]
    if !Set(productSignals).isDisjoint(with: strongProductSignals) { return true }

    return containsAny(lower, ["what changes", "why it matters", "the mistake", "the lesson"])
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
    if hasActionableRule,
       !isVagueActionRule(lower, concretenessScore: breakdown.concrete, topicAlignment: breakdown.topic) {
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
    if hasSponsorOrShoutout(text) { return "sponsor_or_cta" }
    if isInterviewerSetup(lower) { return "interviewer_setup" }
    if hasPodcastMetaFluff(lower) || hasCreatorMetaHook(lower) { return "podcast_or_admin_fluff" }
    if contextBlockLooksPromotional(text) { return "sponsor_or_cta" }
    if isQuestionAnchor(text) { return "question_anchor" }
    if endsWithDanglingPhrase(text) { return "incomplete_fragment" }
    if isProcessSetupAnchor(lower), !hasActionableInstruction(lower) { return "process_or_setup" }
    if isRandomAnecdoteAnchor(lower), topicAlignment < 4, breakdown.concrete < 14 {
        return "random_anecdote"
    }
    if podcastFluffPenalty(lower) <= -20 { return "podcast_or_admin_fluff" }
    if podcastFluffPenalty(lower) < 0, breakdown.consequence == 0, breakdown.contrast == 0 {
        return "interviewer_setup"
    }
    if isVagueActionRule(lower, concretenessScore: breakdown.concrete, topicAlignment: topicAlignment),
       Set(productWorthinessSignals).isSubset(of: ["actionable_rule", "decision_point"]) {
        return "vague_actionable_rule"
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
    contentMode: ContentMode,
    config: MomentRankerConfig
) -> MomentCandidate? {
    let startIndex = max(0, range.lowerBound)
    let endIndex = min(units.count - 1, range.upperBound)
    guard startIndex <= endIndex else { return nil }

    var windowUnits = trimPromotionalLeadInUnits(
        Array(units[startIndex ... endIndex]),
        anchorIndex: anchor.index
    )
    windowUnits = trimDirtyLeadInUnits(
        windowUnits,
        anchorIndex: anchor.index
    )
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
    let productEvaluation = evaluateProductQuality(
        text: text,
        centerSentence: centerSentence,
        contentMode: contentMode,
        baseScore: base,
        productWorthinessSignals: anchor.productWorthinessSignals,
        topicAlignment: anchor.topicAlignment,
        numberIsTopicAligned: anchor.numberIsTopicAligned,
        hasConsequenceNearby: anchor.hasConsequenceNearby,
        concretenessScore: concreteScore,
        insightScore: insightScore,
        selfContainedScore: selfContained,
        anchorScore: anchor.anchorScore,
        chapterTitle: chapterTitle,
        startSeconds: first.startSeconds
    )

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
        productWorthinessSignals: anchor.productWorthinessSignals,
        contentMode: contentMode,
        wouldUserClickScore: productEvaluation.finalScore,
        clickScoreRaw: productEvaluation.rawScore,
        scoreCapApplied: productEvaluation.scoreCapApplied,
        scoreCapReason: productEvaluation.scoreCapReason,
        usefulnessSignals: productEvaluation.usefulnessSignals,
        modeSpecificBoosts: productEvaluation.modeSpecificBoosts,
        modeSpecificPenalties: productEvaluation.modeSpecificPenalties,
        sponsorDetected: productEvaluation.sponsorDetected,
        selectedForProduct: productEvaluation.selectedForProduct
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

private func trimDirtyLeadInUnits(
    _ units: [ImpactUnit],
    anchorIndex: Int
) -> [ImpactUnit] {
    var trimmed = units
    while trimmed.count > 1,
          let first = trimmed.first,
          first.index < anchorIndex,
          hasDirtyOpeningSentence(first.text) {
        let remaining = Array(trimmed.dropFirst())
        guard wordCount(stitchTextSegments(remaining.map(\.text))) >= 16 else { break }
        trimmed = remaining
    }
    return trimmed
}

private func trimPromotionalLeadInUnits(
    _ units: [ImpactUnit],
    anchorIndex: Int
) -> [ImpactUnit] {
    guard units.count > 1 else { return units }

    var trimmed = units
    while let promoIndex = trimmed.firstIndex(where: {
        $0.index < anchorIndex && (hasSponsorOrShoutout($0.text) || hasCreatorMetaHook($0.text.lowercased()))
    }) {
        let nextIndex = promoIndex + 1
        guard nextIndex < trimmed.count else { break }
        let remaining = Array(trimmed[nextIndex...])
        guard remaining.contains(where: { $0.index == anchorIndex }),
              wordCount(stitchTextSegments(remaining.map(\.text))) >= 16 else {
            break
        }
        trimmed = remaining
    }

    return trimmed
}

private func trimDirtyLeadInBlocks(
    blocks: [TranscriptBlock],
    range: ClosedRange<Int>
) -> ClosedRange<Int> {
    var start = max(0, range.lowerBound)
    let end = min(blocks.count - 1, range.upperBound)
    guard start <= end else { return range }

    while start < end,
          blocks.indices.contains(start),
          hasDirtyOpeningSentence(blocks[start].text) {
        let remaining = stitchBlockTexts(Array(blocks[(start + 1) ... end]))
        guard wordCount(remaining) >= 18 else { break }
        start += 1
    }
    return start ... end
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
    contentMode: ContentMode,
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
    let trimmedRange = trimDirtyLeadInBlocks(blocks: blocks, range: snappedRange)
    let windowBlocks = trimmedRange.compactMap { blocks.indices.contains($0) ? blocks[$0] : nil }
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
    let payoffAnchor = bestPayoffAnchor(
        in: text,
        chapterTitle: chapterTitle,
        topicTerms: topicTerms,
        contentMode: contentMode
    )

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
    let productEvaluation = evaluateProductQuality(
        text: text,
        centerSentence: payoffAnchor?.text,
        contentMode: contentMode,
        baseScore: base,
        productWorthinessSignals: productSignals,
        topicAlignment: topicScore,
        numberIsTopicAligned: hasNumber ? numberAligned : nil,
        hasConsequenceNearby: hasConsequence,
        concretenessScore: concreteScore,
        insightScore: insightScore,
        selfContainedScore: selfContained,
        anchorScore: payoffAnchor?.score,
        chapterTitle: chapterTitle,
        startSeconds: first.startSeconds
    )

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
        centerSentence: payoffAnchor?.text,
        anchorScore: payoffAnchor?.score,
        anchorBreakdown: payoffAnchor?.breakdown,
        topicAlignment: payoffAnchor?.topicAlignment ?? topicScore,
        chapterSpecificity: payoffAnchor?.chapterSpecificity ?? specificity,
        numberIsTopicAligned: payoffAnchor?.numberIsTopicAligned ?? (hasNumber ? numberAligned : nil),
        hasConsequenceNearby: payoffAnchor?.hasConsequenceNearby ?? hasConsequence,
        anchorRejected: false,
        rejectionReason: nil,
        productWorthinessSignals: productSignals,
        contentMode: contentMode,
        wouldUserClickScore: productEvaluation.finalScore,
        clickScoreRaw: productEvaluation.rawScore,
        scoreCapApplied: productEvaluation.scoreCapApplied,
        scoreCapReason: productEvaluation.scoreCapReason,
        usefulnessSignals: productEvaluation.usefulnessSignals,
        modeSpecificBoosts: productEvaluation.modeSpecificBoosts,
        modeSpecificPenalties: productEvaluation.modeSpecificPenalties,
        sponsorDetected: productEvaluation.sponsorDetected,
        selectedForProduct: productEvaluation.selectedForProduct
    )
}

// MARK: - Query scoring

private func parseMomentQuery(_ raw: String) -> ParsedMomentQuery? {
    let cleaned = cleanTranscript(raw)
    guard !cleaned.isEmpty else { return nil }

    var phrases: [String] = []
    if let regex = try? NSRegularExpression(pattern: #""([^"]+)"|'([^']+)'"#) {
        let nsRange = NSRange(cleaned.startIndex ..< cleaned.endIndex, in: cleaned)
        for match in regex.matches(in: cleaned, range: nsRange) {
            for index in 1 ..< match.numberOfRanges {
                guard let range = Range(match.range(at: index), in: cleaned) else { continue }
                let phrase = normalizedSearchPhrase(String(cleaned[range]))
                if !phrase.isEmpty { phrases.append(phrase) }
            }
        }
    }

    let normalized = normalizedSearchPhrase(cleaned.replacingOccurrences(of: "\"", with: " "))
    var terms = queryDisplayTokens(cleaned)
        .filter { $0.count >= 2 && !queryStopwords.contains($0) }
    if terms.isEmpty {
        terms = queryDisplayTokens(cleaned).filter { $0.count >= 2 }
    }
    guard !terms.isEmpty else { return nil }

    if terms.count >= 2 {
        phrases.append(normalized)
    }

    var seenTerms = Set<String>()
    let uniqueTerms = terms.filter { seenTerms.insert($0).inserted }
    var variants: [String: Set<String>] = [:]
    for term in uniqueTerms {
        variants[term] = searchTokenVariants(term)
    }

    return ParsedMomentQuery(
        raw: cleaned,
        normalized: normalized,
        terms: uniqueTerms,
        termVariants: variants,
        phrases: Array(Set(phrases)).sorted()
    )
}

private func evaluateQueryMatch(
    text: String,
    chapterTitle: String?,
    parsedQuery: ParsedMomentQuery
) -> QueryMatchEvaluation {
    let normalizedText = normalizedSearchPhrase(text)
    let normalizedChapter = chapterTitle.map(normalizedSearchPhrase) ?? ""
    let tokens = searchTokens(text)
    let chapterTokens = searchTokens(chapterTitle ?? "")

    var score = 0
    var reasons: [String] = []
    var exactPhrase = false
    var chapterSupportsQuery = false
    var chapterBoost = 0
    var matchedTerms: [String] = []
    var positionsByTerm: [String: [Int]] = [:]

    for phrase in parsedQuery.phrases where phrase.count >= 3 {
        if normalizedText.contains(phrase) {
            exactPhrase = true
            score += phrase == parsedQuery.normalized ? 56 : 46
            reasons.append("exact query phrase")
            break
        }
        if normalizedChapter.contains(phrase) {
            chapterSupportsQuery = true
            chapterBoost = max(chapterBoost, 18)
        }
    }

    for term in parsedQuery.terms {
        let variants = parsedQuery.termVariants[term] ?? [term]
        var positions: [Int] = []
        for (idx, token) in tokens.enumerated() where variants.contains(token) {
            positions.append(idx)
        }
        let textMatched = !positions.isEmpty
        if !textMatched, chapterTokens.contains(where: { variants.contains($0) }) {
            chapterSupportsQuery = true
        }
        if textMatched {
            matchedTerms.append(term)
            positionsByTerm[term] = positions
        }
    }

    guard exactPhrase || !matchedTerms.isEmpty else {
        return QueryMatchEvaluation(
            score: 0,
            matchedTerms: [],
            exactPhrase: false,
            allTermsMatched: false,
            proximity: nil,
            reasons: []
        )
    }

    let allTermsMatched = matchedTerms.count == parsedQuery.terms.count
    if !matchedTerms.isEmpty {
        let ratio = Double(matchedTerms.count) / Double(max(1, parsedQuery.terms.count))
        score += Int((ratio * 34.0).rounded())
        reasons.append(allTermsMatched ? "matched all query terms" : "matched query terms")
    }

    let textMatchedTerms = parsedQuery.terms.filter { positionsByTerm[$0]?.isEmpty == false }
    if !textMatchedTerms.isEmpty {
        let frequency = textMatchedTerms.reduce(0) { total, term in
            total + min(4, positionsByTerm[term]?.count ?? 0)
        }
        score += min(12, frequency * 2)
    }

    let proximity = queryTermProximity(positionsByTerm: positionsByTerm, terms: parsedQuery.terms)
    if let proximity {
        if proximity <= 2 {
            score += 22
            reasons.append("query terms adjacent")
        } else if proximity <= 8 {
            score += 16
            reasons.append("query terms close together")
        } else if proximity <= 18 {
            score += 9
            reasons.append("query terms in same moment")
        }
    }

    if chapterSupportsQuery {
        score += max(6, chapterBoost)
        reasons.append("chapter supports query")
    }

    if exactPhrase, !reasons.contains("exact query phrase") {
        reasons.insert("exact query phrase", at: 0)
    }

    return QueryMatchEvaluation(
        score: min(100, max(0, score)),
        matchedTerms: Array(Set(matchedTerms)).sorted(),
        exactPhrase: exactPhrase,
        allTermsMatched: allTermsMatched,
        proximity: proximity,
        reasons: Array(Set(reasons)).sorted()
    )
}

private func queryTermProximity(
    positionsByTerm: [String: [Int]],
    terms: [String]
) -> Int? {
    let positionLists = terms.compactMap { positionsByTerm[$0] }.filter { !$0.isEmpty }
    guard positionLists.count >= 2, positionLists.count == terms.count else { return nil }

    var bestSpan = Int.max
    for list in positionLists {
        for position in list {
            var minPosition = position
            var maxPosition = position
            var valid = true
            for otherList in positionLists where otherList != list {
                guard let nearest = otherList.min(by: { abs($0 - position) < abs($1 - position) }) else {
                    valid = false
                    break
                }
                minPosition = min(minPosition, nearest)
                maxPosition = max(maxPosition, nearest)
            }
            if valid {
                bestSpan = min(bestSpan, maxPosition - minPosition)
            }
        }
    }
    return bestSpan == Int.max ? nil : bestSpan
}

private func queryMatchFloor(_ parsedQuery: ParsedMomentQuery) -> Int {
    parsedQuery.terms.count <= 1 ? 30 : 40
}

private func queryMatchWithIntentBoost(
    _ match: QueryMatchEvaluation,
    intent: QueryIntentEvaluation
) -> QueryMatchEvaluation {
    QueryMatchEvaluation(
        score: min(100, max(0, match.score + intent.score)),
        matchedTerms: match.matchedTerms,
        exactPhrase: match.exactPhrase,
        allTermsMatched: match.allTermsMatched,
        proximity: match.proximity,
        reasons: match.reasons
    )
}

private func queryIntentEvaluation(
    text: String,
    centerSentence: String,
    parsedQuery: ParsedMomentQuery,
    queryMatch: QueryMatchEvaluation,
    anchorEvaluation: AnchorEvaluation
) -> QueryIntentEvaluation {
    guard queryMatch.score > 0 else {
        return QueryIntentEvaluation(score: 0, signals: [], reasons: [])
    }

    let lower = text.lowercased()
    let center = centerSentence.lowercased()
    let queryIsClose = queryMatch.exactPhrase
        || queryMatch.allTermsMatched
        || (queryMatch.proximity ?? Int.max) <= 8
        || parsedQuery.terms.count == 1

    var score = 0
    var signals = Set<String>()
    var reasons = Set<String>()

    func add(_ signal: String, _ points: Int, _ reason: String) {
        guard queryIsClose else { return }
        score += points
        signals.insert(signal)
        reasons.insert(reason)
    }

    let payoffSignals = Set(anchorEvaluation.productWorthinessSignals)
    if hasConsequenceLanguage(center) || hasConsequenceLanguage(lower) || payoffSignals.contains("consequence") {
        add("query_consequence", 12, "shows query consequence")
    }
    if containsAny(center, ["because", "reason", "why", "this means", "means that", "therefore", "as a result"]) {
        add("query_explanation", 10, "explains query concept")
    }
    if containsAny(center, ["instead of", "rather than", "tradeoff", "decision", "rule", "mistake", "should", "need to", "have to"]) || payoffSignals.contains("decision_point") {
        add("query_decision", 9, "ties query to a decision or tradeoff")
    }
    if payoffSignals.contains("surprising_claim")
        || containsAny(center, ["turns out", "surprising", "counterintuitive", "unexpected"]) {
        add("query_surprise", 7, "surprising query-relevant claim")
    }
    if queryMatch.exactPhrase, !signals.isEmpty {
        score += 4
        reasons.insert("exact phrase near payoff")
    }

    return QueryIntentEvaluation(
        score: min(24, max(0, score)),
        signals: Array(signals).sorted(),
        reasons: Array(reasons).sorted()
    )
}

private func queryRamblingPenalty(_ text: String) -> Int {
    let words = wordCount(text)
    let terminalCount = text.reduce(0) { total, character in
        total + (".?!".contains(character) ? 1 : 0)
    }
    if words >= 70 { return 35 }
    if words > 45, terminalCount == 0 { return 30 }
    if words > 40, !endsLikelyComplete(text) { return 24 }
    if words > 55 { return 18 }
    return 0
}

private func queryMentionOnlyPenalty(
    queryMatch: QueryMatchEvaluation,
    intent: QueryIntentEvaluation,
    productSignals: [String],
    centerSentence: String
) -> Int {
    if intent.score > 0 { return 0 }
    let lower = centerSentence.lowercased()
    let strongProductSignals: Set<String> = [
        "consequence", "strong_contrast", "decision_point", "actionable_rule",
        "surprising_claim", "topic_aligned_number", "topic_aligned_concrete_evidence"
    ]
    if !Set(productSignals).isDisjoint(with: strongProductSignals) { return 0 }
    if hasConsequenceLanguage(lower) { return 0 }
    if queryMatch.exactPhrase || queryMatch.allTermsMatched { return 20 }
    return 12
}

private func queryCenterNeedsPreviousContext(_ text: String) -> Bool {
    let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if startsWithDanglingWindowPronoun(text) { return true }
    let productiveThisPattern = #"^(?:with|using|through|in|on|for|from|as|at)\b[^.?!]{0,140},?\s+this\s+(?:means|allows|lets|creates|turns|shows|unlocks)\b"#
    if lower.range(of: productiveThisPattern, options: .regularExpression) != nil {
        return false
    }
    let pattern = #"^(?:with|using|through|in|on|for|from|as|at)\b[^.?!]{0,140},?\s+(?:he|she|it|they|this|that)\s+(?:can|could|will|would|is|are|was|were|gives?|allows?|lets?|means|needs?|has|have)\b"#
    return lower.range(of: pattern, options: .regularExpression) != nil
}

private func queryBoundaryQuality(
    text: String,
    wordCount: Int,
    selfContainedScore: Int
) -> Int {
    var score = 28 + min(52, selfContainedScore * 4)
    if wordCount >= 18 && wordCount <= 180 { score += 10 }
    if wordCount >= 28 && wordCount <= 140 { score += 6 }
    if startsLikelyIncomplete(text) { score -= 18 }
    if endsLikelyIncomplete(text) { score -= 18 }
    if hasDirtyOpeningSentence(text) { score -= 16 }
    if startsWithDanglingWindowPronoun(text) { score -= 12 }
    score -= min(22, queryRamblingPenalty(text))
    if text.contains(".") || text.contains("?") || text.contains("!") { score += 6 }
    return min(100, max(0, score))
}

private func queryMomentQuality(
    productEvaluation: ProductEvaluation,
    queryMatch: QueryMatchEvaluation,
    insightScore: Int,
    concreteScore: Int,
    selfContainedScore: Int,
    qualityPenalty: Int,
    productSignals: [String]
) -> Int {
    var score = productEvaluation.finalScore
    let fallback = 34
        + min(20, insightScore)
        + min(16, concreteScore / 2)
        + min(16, selfContainedScore)
        + max(-16, qualityPenalty / 2)
        + min(12, productSignals.count * 4)
    if queryMatch.score >= 70 {
        score = max(score, min(78, fallback + 8))
    } else if queryMatch.score >= 45 {
        score = max(score, min(72, fallback))
    }
    return min(100, max(0, score))
}

private func combinedQueryScore(
    queryMatch: Int,
    momentQuality: Int,
    boundaryQuality: Int,
    diversity: Int
) -> Int {
    let score = (Double(queryMatch) * 0.50)
        + (Double(momentQuality) * 0.25)
        + (Double(boundaryQuality) * 0.15)
        + (Double(diversity) * 0.10)
    return min(100, max(0, Int(score.rounded())))
}

private func queryStrength(
    combinedScore: Int,
    queryMatch: QueryMatchEvaluation,
    momentQuality: Int,
    boundaryQuality: Int
) -> QueryMomentStrength {
    if combinedScore >= 78,
       queryMatch.score >= 70,
       boundaryQuality >= 68,
       momentQuality >= 58 {
        return .strong
    }
    if combinedScore >= 55,
       queryMatch.score >= 34,
       momentQuality >= 45,
       boundaryQuality >= 60 {
        return .medium
    }
    return .weak
}

private func aggregateQueryStrength(_ moments: [RankedMoment]) -> QueryMomentStrength? {
    guard let first = moments.first?.queryStrength else { return nil }
    return QueryMomentStrength(rawValue: first) ?? .weak
}

private func videoURLAtTime(sourceURL: String, startSeconds: Double) -> String? {
    guard !sourceURL.isEmpty else { return nil }
    let seconds = max(0, Int(startSeconds.rounded(.down)))

    if var components = URLComponents(string: sourceURL) {
        let timestampKeys: Set<String> = ["t", "start", "time_continue"]
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { timestampKeys.contains($0.name.lowercased()) }
        queryItems.append(URLQueryItem(name: "t", value: "\(seconds)s"))
        components.queryItems = queryItems
        if let value = components.string { return value }
    }

    let separator = sourceURL.contains("?") ? "&" : "?"
    return "\(sourceURL)\(separator)t=\(seconds)s"
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
    if hasNativeAdRead(text) || hasCreatorMetaHook(lower) { return true }
    if hardLeadInScore(String(lower.prefix(700))) >= 16 { return true }
    let phrases = [
        "vanta.com", "workos.com", "works.com", "supporting sponsor",
        "make sure to subscribe", "click the subscribe", "join the new society",
        "promo code", "use code", "learn more at", "try it risk-free",
        "abundant mines", "own your machines", "bitcoin you mine",
        "by the end of this video", "by the end of the episode",
        "go to this talk", "hit subscribe"
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
        ("go ahead below the video", -12),
        ("try it risk-free", -24),
        ("risk-free for 30 days", -24),
        ("abundant mines", -24),
        ("own your machines", -20),
        ("bitcoin you mine", -20),
        ("by the end of this video", -18),
        ("by the end of the episode", -18),
        ("let's get into it", -12),
        ("go to this talk", -18),
        ("hit subscribe", -18)
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
    if hasNativeAdRead(text) { return 24 }
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
        ("try it risk-free", 18),
        ("risk-free for 30 days", 18),
        ("abundant mines", 18),
        ("own your machines", 14),
        ("bitcoin you mine", 14),
        ("by the end of this video", 16),
        ("by the end of the episode", 16),
        ("go to this talk", 16),
        ("hit subscribe", 18),
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
        $0.baseScore >= max(0, qualityThreshold - 12)
            && $0.productSelectionScore >= 75
            && $0.rejectionReason == nil
            && $0.selectedForProduct
            && !$0.sponsorDetected
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
            let selectionScore = candidate.productSelectionScore
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

private func selectQueryMoments(
    candidates: [QueryMomentCandidate],
    limit: Int
) -> QuerySelectionResult {
    guard !candidates.isEmpty else {
        return QuerySelectionResult(selected: [], dedupedOverlaps: [])
    }

    let viable = candidates.filter { $0.combinedScore >= 45 }
    let hasProductStrength = viable.contains { $0.queryStrength != .weak }
    let pool = hasProductStrength
        ? viable.filter { $0.queryStrength != .weak }
        : Array(viable.prefix(min(limit, 3)))

    var selected: [SelectedQueryCandidate] = []
    var deduped: [DedupedQueryOverlap] = []

    for candidate in pool {
        if selected.count >= limit { break }

        let duplicate = selected
            .map { selectedCandidate -> (selected: SelectedQueryCandidate, similarity: Double, temporal: Double) in
                (
                    selectedCandidate,
                    similarity(candidate.candidate, selectedCandidate.candidate.candidate),
                    temporalSimilarity(candidate.candidate, selectedCandidate.candidate.candidate)
                )
            }
            .first {
                $0.similarity > 0.82 || $0.temporal > 0.30
            }

        if let duplicate {
            let duplicateIndex = selected.firstIndex {
                $0.candidate.candidate.startSeconds == duplicate.selected.candidate.candidate.startSeconds
            } ?? max(0, selected.count - 1)
            deduped.append(
                DedupedQueryOverlap(
                    id: "qd\(deduped.count + 1)",
                    duplicateOf: "q\(duplicateIndex + 1)",
                    startSeconds: roundTime(candidate.candidate.startSeconds),
                    endSeconds: roundTime(candidate.candidate.endSeconds),
                    overlapRatio: roundConfidence(duplicate.temporal),
                    similarity: roundConfidence(duplicate.similarity),
                    reason: duplicate.temporal > 0.30 ? "temporal_overlap" : "lexical_overlap",
                    centerSentence: candidate.candidate.centerSentence ?? ""
                )
            )
            continue
        }

        let maxSimilarity = selected
            .map { similarity(candidate.candidate, $0.candidate.candidate) }
            .max() ?? 0.0
        let maxTemporal = selected
            .map { temporalSimilarity(candidate.candidate, $0.candidate.candidate) }
            .max() ?? 0.0
        let diversity = selected.isEmpty
            ? 10
            : max(0, Int(((1.0 - maxSimilarity) * 10.0).rounded()) - Int((maxTemporal * 8.0).rounded()))

        selected.append(SelectedQueryCandidate(candidate: candidate, diversityBonus: diversity))
    }

    return QuerySelectionResult(selected: selected, dedupedOverlaps: deduped)
}

private func passesFinalProductGate(_ candidate: MomentCandidate) -> Bool {
    guard candidate.selectedForProduct,
          candidate.wouldUserClickScore >= 75,
          !candidate.sponsorDetected else {
        return false
    }
    guard candidate.anchorScore != nil,
          candidate.centerSentence?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        return false
    }

    let usefulnessSignals = Set(candidate.usefulnessSignals)
    let hasNumber = candidate.cleanText.range(of: #"\d"#, options: .regularExpression) != nil
    let topicAlignment = candidate.topicAlignment ?? 0
    if topicAlignment == 0, candidate.wouldUserClickScore < 85 {
        return false
    }

    if hasNumber,
       candidate.numberIsTopicAligned == false,
       topicAlignment == 0,
       usefulnessSignals.isDisjoint(with: ["clear_consequence", "causal_explanation", "decision_or_tradeoff"]) {
        return false
    }

    return true
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

private let queryStopwords: Set<String> = stopwords.union([
    "find", "show", "give", "moment", "moments", "clip", "clips", "video"
])

private func normalizedSearchPhrase(_ text: String) -> String {
    searchTokens(text).joined(separator: " ")
}

private func queryDisplayTokens(_ text: String) -> [String] {
    text
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .map(normalizedToken)
        .filter { !$0.isEmpty }
}

private func searchTokens(_ text: String) -> [String] {
    text
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .map(stemSearchToken)
        .filter { !$0.isEmpty }
}

private func searchTokenVariants(_ token: String) -> Set<String> {
    let stem = stemSearchToken(token)
    var variants = Set([token, stem].filter { !$0.isEmpty })

    if stem == "ai" {
        variants.formUnion(["ai", "artificial", "intelligence"])
    }
    if stem == "local" {
        variants.insert("locally")
    }
    if stem == "price" {
        variants.formUnion(["pricing", "priced", "prices"])
    }
    if stem == "cost" {
        variants.formUnion(["costs", "costing"])
    }
    if stem == "model" {
        variants.insert("models")
    }
    if stem == "agent" {
        variants.insert("agents")
    }

    return variants.map(stemSearchToken).reduce(into: variants) { $0.insert($1) }
}

private func stemSearchToken(_ token: String) -> String {
    var value = normalizedToken(token)
    guard value.count > 3 else { return value }

    if value.hasSuffix("ies"), value.count > 5 {
        value = String(value.dropLast(3)) + "y"
    } else if value.hasSuffix("ing"), value.count > 5 {
        value = String(value.dropLast(3))
        if value.hasSuffix("c") { value += "e" }
        value = dropDoubledFinalConsonant(value)
    } else if value.hasSuffix("ed"), value.count > 4 {
        value = String(value.dropLast(2))
        value = dropDoubledFinalConsonant(value)
    } else if value.hasSuffix("ly"), value.count > 5 {
        value = String(value.dropLast(2))
    } else if value.hasSuffix("es"), value.count > 4 {
        value = String(value.dropLast(2))
    } else if value.hasSuffix("s"), value.count > 4, !value.hasSuffix("ss") {
        value = String(value.dropLast())
    }

    return value
}

private func dropDoubledFinalConsonant(_ value: String) -> String {
    guard value.count >= 2,
          let last = value.last else { return value }
    let previous = value[value.index(before: value.index(before: value.endIndex))]
    let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
    if last == previous, !vowels.contains(last) {
        return String(value.dropLast())
    }
    return value
}

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
    cleaned = trimDirtyOpeningSentence(cleaned)
    cleaned = trimLeadingPunctuationArtifacts(cleaned)
    cleaned = dropOrphanedQuoteFragments(cleaned)
    cleaned = dropRepeatedLeadInSentences(cleaned)
    cleaned = trimTrailingFragment(cleaned)
    cleaned = trimLeadingPunctuationArtifacts(cleaned)
    cleaned = stripLeadingFiller(cleaned)
    cleaned = normalizeLeadingFalseStarts(cleaned)
    cleaned = trimTrailingFiller(cleaned)
    cleaned = collapseRepeatedWords(cleaned)
    cleaned = trimLeadingPunctuationArtifacts(cleaned)
    return capitalizeMomentStart(cleanTranscript(cleaned))
}

private func trimDirtyOpeningSentence(_ text: String) -> String {
    let cleaned = cleanTranscript(text)
    var sentences = sentenceRanges(in: cleaned)
        .map { String(cleaned[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    while sentences.count > 1, let first = sentences.first {
        guard isDirtyLeadInSentence(first) || startsLikelyIncomplete(first) else { break }

        let remainder = sentences.dropFirst().joined(separator: " ")
        guard wordCount(remainder) >= 18 else { break }
        sentences.removeFirst()
    }

    return cleanTranscript(sentences.joined(separator: " "))
}

private func trimLeadingPunctuationArtifacts(_ text: String) -> String {
    var cleaned = cleanTranscript(text)
    let pattern = #"^[\s"'“”‘’.,;:\-–—\]\)]+(?=[A-Za-z0-9])"#
    for _ in 0 ..< 3 {
        let next = cleaned.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
        if next == cleaned { break }
        cleaned = cleanTranscript(next)
    }
    return cleaned
}

private func dropOrphanedQuoteFragments(_ text: String) -> String {
    var sentences = sentenceRanges(in: text)
        .map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !sentences.isEmpty else { return text }

    var index = 0
    while index < sentences.count {
        if isOrphanedQuoteFragment(sentences[index]) {
            var remaining = sentences
            remaining.remove(at: index)
            let candidate = remaining.joined(separator: " ")
            guard wordCount(candidate) >= 18 else { break }
            sentences.remove(at: index)
            continue
        }
        index += 1
    }

    return cleanTranscript(sentences.joined(separator: " "))
}

private func isOrphanedQuoteFragment(_ sentence: String) -> Bool {
    let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first, "\"'“”‘’".contains(first) else { return false }
    let stripped = trimLeadingPunctuationArtifacts(trimmed)
    let lower = stripped.lowercased()
    if lower.isEmpty { return true }

    let weakPrefixes = [
        "is ", "are ", "was ", "were ", "be ", "been ", "being ",
        "as ", "and ", "but ", "so ", "because ", "even though ",
        "like ", "that ", "which ", "who ", "what ", "why ", "how "
    ]
    if weakPrefixes.contains(where: lower.hasPrefix) { return true }

    if let first = stripped.unicodeScalars.first,
       CharacterSet.lowercaseLetters.contains(first) {
        return true
    }

    return false
}

private func hasDirtyOpeningSentence(_ text: String) -> Bool {
    let cleaned = cleanTranscript(text)
    let sentences = sentenceRanges(in: cleaned)
        .map { String(cleaned[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard let first = sentences.first else { return false }
    return isDirtyLeadInSentence(first)
}

private func isDirtyLeadInSentence(_ sentence: String) -> Bool {
    let cleaned = cleanTranscript(sentence)
    let lower = cleaned.lowercased()
    let words = wordCount(cleaned)

    if hasCreatorMetaHook(lower) { return true }
    if startsWithDanglingWindowPronoun(cleaned) { return true }
    if hasDanglingPronounStart(cleaned) { return true }
    if isOrphanedQuoteFragment(cleaned) { return true }
    if containsAny(
        lower,
        [
            "thoughts on this", "you were going to say", "i was just agreeing",
            "i'm just agreeing", "i agree", "you got to try it", "let's get into it",
            "go to this talk", "what do you think", "what are your thoughts"
        ]
    ) {
        return true
    }

    if cleaned.range(
        of: #"^[A-Z][A-Za-z]{2,16},\s+(thoughts|you were|what do|did you|can you|go ahead)"#,
        options: .regularExpression
    ) != nil {
        return true
    }

    if words < 8 {
        let hasPayoffCue = hasConsequenceLanguage(lower)
            || lower.range(of: #"\d"#, options: .regularExpression) != nil
            || containsAny(lower, ["the key", "mistake", "turns out", "changed", "because"])
        return !hasPayoffCue
    }

    return false
}

private func startsWithDanglingWindowPronoun(_ sentence: String) -> Bool {
    let lower = sentence.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if lower.hasPrefix("this means ")
        || lower.hasPrefix("this is why ")
        || lower.hasPrefix("this lets ")
        || lower.hasPrefix("this allows ")
        || lower.hasPrefix("this creates ")
        || lower.hasPrefix("this turns ") {
        return false
    }

    let hardDanglingPrefixes = [
        "it ", "it'", "he ", "she ", "they ", "that ", "these ", "those ",
        "the man who ", "the guy who ", "the person who "
    ]
    if hardDanglingPrefixes.contains(where: lower.hasPrefix) { return true }

    if lower.hasPrefix("this ") {
        let firstEightWords = lower
            .split(whereSeparator: \.isWhitespace)
            .prefix(8)
            .joined(separator: " ")
        return firstEightWords.range(of: #"\d"#, options: .regularExpression) == nil
            && !hasConcreteSubjectCue(firstEightWords)
    }

    return false
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
