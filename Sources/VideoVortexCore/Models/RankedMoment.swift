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
        whySelected: [String]
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

/// Output shape for the dev/eval `vvx moments` command.
public struct MomentRankingResult: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let success: Bool
    public let sourceTitle: String
    public let sourceURL: String
    public let rankedMoments: [RankedMoment]
    public let momentCandidates: [RankedMoment]?

    public init(
        schemaVersion: String = "1.0",
        sourceTitle: String,
        sourceURL: String,
        rankedMoments: [RankedMoment],
        momentCandidates: [RankedMoment]? = nil
    ) {
        self.schemaVersion   = schemaVersion
        self.success         = true
        self.sourceTitle     = sourceTitle
        self.sourceURL       = sourceURL
        self.rankedMoments   = rankedMoments
        self.momentCandidates = momentCandidates
    }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
