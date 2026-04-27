import Foundation

/// A ranked, timestamped video moment selected from transcript structure.
///
/// Public product output uses `SenseResult.rankedMoments`. Debug/eval output may
/// also expose pre-MMR `momentCandidates`.
public struct RankedMoment: Codable, Sendable, Equatable {
    public let id: String
    public let rank: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public let durationSeconds: Double
    public let titleHint: String
    public let cleanText: String
    public let score: Int
    public let candidateType: MomentCandidateType
    public let confidence: Double
    public let chapterTitle: String?
    public let chapterIndex: Int?
    public let scoreBreakdown: MomentScoreBreakdown
    public let whySelected: [String]
    public let centerSentence: String?
    public let anchorScore: Int?
    public let anchorBreakdown: MomentAnchorBreakdown?
    public let topicAlignment: Int?
    public let chapterSpecificity: Double?
    public let numberIsTopicAligned: Bool?
    public let hasConsequenceNearby: Bool?
    public let anchorRejected: Bool?
    public let rejectionReason: String?
    public let productWorthinessSignals: [String]?
    public let contentMode: String?
    public let wouldUserClickScore: Int?
    public let clickScoreRaw: Int?
    public let clickScoreFinal: Int?
    public let scoreCapApplied: Bool?
    public let scoreCapReason: String?
    public let usefulnessSignals: [String]?
    public let modeSpecificBoosts: [String]?
    public let modeSpecificPenalties: [String]?
    public let sponsorDetected: Bool?
    public let selectedForProduct: Bool?
    public let queryStrength: String?
    public let matchedTerms: [String]?
    public let queryMatchScore: Int?
    public let queryIntentScore: Int?
    public let queryIntentSignals: [String]?
    public let momentQualityScore: Int?
    public let boundaryQualityScore: Int?
    public let combinedScore: Int?
    public let queryScoreBreakdown: QueryMomentScoreBreakdown?
    public let videoURLAtTime: String?
    public let queryEvidence: QueryEvidence?

    public init(
        id: String,
        rank: Int,
        startSeconds: Double,
        endSeconds: Double,
        durationSeconds: Double,
        titleHint: String,
        cleanText: String,
        score: Int,
        candidateType: MomentCandidateType,
        confidence: Double,
        chapterTitle: String?,
        chapterIndex: Int?,
        scoreBreakdown: MomentScoreBreakdown,
        whySelected: [String],
        centerSentence: String? = nil,
        anchorScore: Int? = nil,
        anchorBreakdown: MomentAnchorBreakdown? = nil,
        topicAlignment: Int? = nil,
        chapterSpecificity: Double? = nil,
        numberIsTopicAligned: Bool? = nil,
        hasConsequenceNearby: Bool? = nil,
        anchorRejected: Bool? = nil,
        rejectionReason: String? = nil,
        productWorthinessSignals: [String]? = nil,
        contentMode: String? = nil,
        wouldUserClickScore: Int? = nil,
        clickScoreRaw: Int? = nil,
        clickScoreFinal: Int? = nil,
        scoreCapApplied: Bool? = nil,
        scoreCapReason: String? = nil,
        usefulnessSignals: [String]? = nil,
        modeSpecificBoosts: [String]? = nil,
        modeSpecificPenalties: [String]? = nil,
        sponsorDetected: Bool? = nil,
        selectedForProduct: Bool? = nil,
        queryStrength: String? = nil,
        matchedTerms: [String]? = nil,
        queryMatchScore: Int? = nil,
        queryIntentScore: Int? = nil,
        queryIntentSignals: [String]? = nil,
        momentQualityScore: Int? = nil,
        boundaryQualityScore: Int? = nil,
        combinedScore: Int? = nil,
        queryScoreBreakdown: QueryMomentScoreBreakdown? = nil,
        videoURLAtTime: String? = nil,
        queryEvidence: QueryEvidence? = nil
    ) {
        self.id             = id
        self.rank           = rank
        self.startSeconds   = startSeconds
        self.endSeconds     = endSeconds
        self.durationSeconds = durationSeconds
        self.titleHint      = titleHint
        self.cleanText      = cleanText
        self.score          = score
        self.candidateType  = candidateType
        self.confidence     = confidence
        self.chapterTitle   = chapterTitle
        self.chapterIndex   = chapterIndex
        self.scoreBreakdown = scoreBreakdown
        self.whySelected    = whySelected
        self.centerSentence = centerSentence
        self.anchorScore = anchorScore
        self.anchorBreakdown = anchorBreakdown
        self.topicAlignment = topicAlignment
        self.chapterSpecificity = chapterSpecificity
        self.numberIsTopicAligned = numberIsTopicAligned
        self.hasConsequenceNearby = hasConsequenceNearby
        self.anchorRejected = anchorRejected
        self.rejectionReason = rejectionReason
        self.productWorthinessSignals = productWorthinessSignals
        self.contentMode = contentMode
        self.wouldUserClickScore = wouldUserClickScore
        self.clickScoreRaw = clickScoreRaw
        self.clickScoreFinal = clickScoreFinal
        self.scoreCapApplied = scoreCapApplied
        self.scoreCapReason = scoreCapReason
        self.usefulnessSignals = usefulnessSignals
        self.modeSpecificBoosts = modeSpecificBoosts
        self.modeSpecificPenalties = modeSpecificPenalties
        self.sponsorDetected = sponsorDetected
        self.selectedForProduct = selectedForProduct
        self.queryStrength = queryStrength
        self.matchedTerms = matchedTerms
        self.queryMatchScore = queryMatchScore
        self.queryIntentScore = queryIntentScore
        self.queryIntentSignals = queryIntentSignals
        self.momentQualityScore = momentQualityScore
        self.boundaryQualityScore = boundaryQualityScore
        self.combinedScore = combinedScore
        self.queryScoreBreakdown = queryScoreBreakdown
        self.videoURLAtTime = videoURLAtTime
        self.queryEvidence = queryEvidence
    }
}

public enum MomentCandidateType: String, Codable, Sendable, Equatable {
    case insight
    case concreteClaim
    case comparison
    case chapterMoment
    case explanation
}

public struct MomentScoreBreakdown: Codable, Sendable, Equatable {
    public let topicRelevance: Int
    public let insight: Int
    public let concreteness: Int
    public let selfContained: Int
    public let chapter: Int
    public let qualityPenalty: Int
    public let mmrDiversity: Int

    public init(
        topicRelevance: Int,
        insight: Int,
        concreteness: Int,
        selfContained: Int,
        chapter: Int,
        qualityPenalty: Int,
        mmrDiversity: Int = 0
    ) {
        self.topicRelevance = topicRelevance
        self.insight        = insight
        self.concreteness   = concreteness
        self.selfContained  = selfContained
        self.chapter        = chapter
        self.qualityPenalty = qualityPenalty
        self.mmrDiversity   = mmrDiversity
    }

    public var baseScore: Int {
        topicRelevance + insight + concreteness + selfContained + chapter + qualityPenalty
    }

    public func withMMRDiversity(_ value: Int) -> MomentScoreBreakdown {
        MomentScoreBreakdown(
            topicRelevance: topicRelevance,
            insight:        insight,
            concreteness:   concreteness,
            selfContained:  selfContained,
            chapter:        chapter,
            qualityPenalty: qualityPenalty,
            mmrDiversity:   value
        )
    }
}

public enum QueryMomentStrength: String, Codable, Sendable, Equatable {
    case strong
    case medium
    case weak
}

/// Query-first display contract for single-video search moments.
///
/// `cleanText` remains the surrounding context window; this shape identifies the
/// specific sentence/span that justified the query match so clients can make the
/// match sentence the visual focus.
public struct QueryEvidence: Codable, Sendable, Equatable {
    public let displayTitle: String
    public let matchSentence: String
    public let matchStartSeconds: Double
    public let matchEndSeconds: Double
    public let matchedTerms: [String]
    public let highlightRanges: [QueryHighlightRange]
    public let contextText: String
    public let urlAtMatch: String?
    public let queryMatchScore: Int

    public init(
        displayTitle: String,
        matchSentence: String,
        matchStartSeconds: Double,
        matchEndSeconds: Double,
        matchedTerms: [String],
        highlightRanges: [QueryHighlightRange],
        contextText: String,
        urlAtMatch: String?,
        queryMatchScore: Int
    ) {
        self.displayTitle = displayTitle
        self.matchSentence = matchSentence
        self.matchStartSeconds = matchStartSeconds
        self.matchEndSeconds = matchEndSeconds
        self.matchedTerms = matchedTerms
        self.highlightRanges = highlightRanges
        self.contextText = contextText
        self.urlAtMatch = urlAtMatch
        self.queryMatchScore = queryMatchScore
    }
}

/// Character offsets into `QueryEvidence.matchSentence`.
public struct QueryHighlightRange: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int
    public let term: String

    public init(start: Int, end: Int, term: String) {
        self.start = start
        self.end = end
        self.term = term
    }
}

public struct QueryMomentScoreBreakdown: Codable, Sendable, Equatable {
    public let queryMatch: Int
    public let queryIntent: Int?
    public let momentQuality: Int
    public let boundaryQuality: Int
    public let diversity: Int
    public let combined: Int

    public init(
        queryMatch: Int,
        queryIntent: Int? = nil,
        momentQuality: Int,
        boundaryQuality: Int,
        diversity: Int = 0,
        combined: Int
    ) {
        self.queryMatch = queryMatch
        self.queryIntent = queryIntent
        self.momentQuality = momentQuality
        self.boundaryQuality = boundaryQuality
        self.diversity = diversity
        self.combined = combined
    }
}

public struct MomentAnchorBreakdown: Codable, Sendable, Equatable {
    public let consequence: Int
    public let contrast: Int
    public let decision: Int
    public let concrete: Int
    public let novelty: Int
    public let outcome: Int
    public let topic: Int
    public let processPenalty: Int
    public let qualityPenalty: Int

    public init(
        consequence: Int,
        contrast: Int,
        decision: Int,
        concrete: Int,
        novelty: Int,
        outcome: Int,
        topic: Int,
        processPenalty: Int,
        qualityPenalty: Int
    ) {
        self.consequence = consequence
        self.contrast = contrast
        self.decision = decision
        self.concrete = concrete
        self.novelty = novelty
        self.outcome = outcome
        self.topic = topic
        self.processPenalty = processPenalty
        self.qualityPenalty = qualityPenalty
    }

    public var score: Int {
        consequence + contrast + decision + concrete + novelty + outcome + topic + processPenalty + qualityPenalty
    }
}

public struct RejectedMomentAnchor: Codable, Sendable, Equatable {
    public let id: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let centerSentence: String
    public let chapterTitle: String?
    public let chapterIndex: Int?
    public let anchorScore: Int
    public let anchorBreakdown: MomentAnchorBreakdown
    public let topicAlignment: Int
    public let chapterSpecificity: Double
    public let numberIsTopicAligned: Bool
    public let hasConsequenceNearby: Bool
    public let anchorRejected: Bool
    public let rejectionReason: String
    public let productWorthinessSignals: [String]

    public init(
        id: String,
        startSeconds: Double,
        endSeconds: Double,
        centerSentence: String,
        chapterTitle: String?,
        chapterIndex: Int?,
        anchorScore: Int,
        anchorBreakdown: MomentAnchorBreakdown,
        topicAlignment: Int,
        chapterSpecificity: Double,
        numberIsTopicAligned: Bool,
        hasConsequenceNearby: Bool,
        anchorRejected: Bool = true,
        rejectionReason: String,
        productWorthinessSignals: [String]
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.centerSentence = centerSentence
        self.chapterTitle = chapterTitle
        self.chapterIndex = chapterIndex
        self.anchorScore = anchorScore
        self.anchorBreakdown = anchorBreakdown
        self.topicAlignment = topicAlignment
        self.chapterSpecificity = chapterSpecificity
        self.numberIsTopicAligned = numberIsTopicAligned
        self.hasConsequenceNearby = hasConsequenceNearby
        self.anchorRejected = anchorRejected
        self.rejectionReason = rejectionReason
        self.productWorthinessSignals = productWorthinessSignals
    }
}

public struct RejectedQueryAnchor: Codable, Sendable, Equatable {
    public let id: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let centerSentence: String
    public let chapterTitle: String?
    public let chapterIndex: Int?
    public let queryMatchScore: Int
    public let matchedTerms: [String]
    public let rejectionReason: String

    public init(
        id: String,
        startSeconds: Double,
        endSeconds: Double,
        centerSentence: String,
        chapterTitle: String?,
        chapterIndex: Int?,
        queryMatchScore: Int,
        matchedTerms: [String],
        rejectionReason: String
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.centerSentence = centerSentence
        self.chapterTitle = chapterTitle
        self.chapterIndex = chapterIndex
        self.queryMatchScore = queryMatchScore
        self.matchedTerms = matchedTerms
        self.rejectionReason = rejectionReason
    }
}

public struct DedupedQueryOverlap: Codable, Sendable, Equatable {
    public let id: String
    public let duplicateOf: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let overlapRatio: Double
    public let similarity: Double
    public let reason: String
    public let centerSentence: String

    public init(
        id: String,
        duplicateOf: String,
        startSeconds: Double,
        endSeconds: Double,
        overlapRatio: Double,
        similarity: Double,
        reason: String,
        centerSentence: String
    ) {
        self.id = id
        self.duplicateOf = duplicateOf
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.overlapRatio = overlapRatio
        self.similarity = similarity
        self.reason = reason
        self.centerSentence = centerSentence
    }
}

/// Output shape for the dev/eval `vvx moments` command.
public struct MomentRankingResult: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let success: Bool
    public let sourceTitle: String
    public let sourceURL: String
    public let rankedMoments: [RankedMoment]
    public let momentCandidates: [RankedMoment]?
    public let rejectedAnchors: [RejectedMomentAnchor]?

    public init(
        schemaVersion: String = "1.0",
        sourceTitle: String,
        sourceURL: String,
        rankedMoments: [RankedMoment],
        momentCandidates: [RankedMoment]? = nil,
        rejectedAnchors: [RejectedMomentAnchor]? = nil
    ) {
        self.schemaVersion   = schemaVersion
        self.success         = true
        self.sourceTitle     = sourceTitle
        self.sourceURL       = sourceURL
        self.rankedMoments   = rankedMoments
        self.momentCandidates = momentCandidates
        self.rejectedAnchors = rejectedAnchors
    }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

/// Output shape for query-specific moments. Public output keeps `rankedMoments`
/// so UI callers can render the same card list, while debug names the query path.
public struct QueryMomentRankingResult: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let success: Bool
    public let mode: String
    public let sourceTitle: String
    public let sourceURL: String
    public let query: String
    public let queryStrength: QueryMomentStrength?
    public let noResultReason: String?
    public let rankedMoments: [RankedMoment]
    public let queryCandidates: [RankedMoment]?
    public let rejectedQueryAnchors: [RejectedQueryAnchor]?
    public let dedupedOverlaps: [DedupedQueryOverlap]?

    public init(
        schemaVersion: String = "1.0",
        sourceTitle: String,
        sourceURL: String,
        query: String,
        queryStrength: QueryMomentStrength?,
        noResultReason: String?,
        rankedMoments: [RankedMoment],
        queryCandidates: [RankedMoment]? = nil,
        rejectedQueryAnchors: [RejectedQueryAnchor]? = nil,
        dedupedOverlaps: [DedupedQueryOverlap]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.success = true
        self.mode = "queryMoments"
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.query = query
        self.queryStrength = queryStrength
        self.noResultReason = noResultReason
        self.rankedMoments = rankedMoments
        self.queryCandidates = queryCandidates
        self.rejectedQueryAnchors = rejectedQueryAnchors
        self.dedupedOverlaps = dedupedOverlaps
    }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
