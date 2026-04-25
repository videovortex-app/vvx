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
    public let usefulnessSignals: [String]?
    public let modeSpecificBoosts: [String]?
    public let modeSpecificPenalties: [String]?
    public let sponsorDetected: Bool?
    public let selectedForProduct: Bool?

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
        usefulnessSignals: [String]? = nil,
        modeSpecificBoosts: [String]? = nil,
        modeSpecificPenalties: [String]? = nil,
        sponsorDetected: Bool? = nil,
        selectedForProduct: Bool? = nil
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
        self.usefulnessSignals = usefulnessSignals
        self.modeSpecificBoosts = modeSpecificBoosts
        self.modeSpecificPenalties = modeSpecificPenalties
        self.sponsorDetected = sponsorDetected
        self.selectedForProduct = selectedForProduct
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
