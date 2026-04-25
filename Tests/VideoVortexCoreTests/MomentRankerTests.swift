import Foundation
import Testing
@testable import VideoVortexCore

@Suite("MomentRanker")
struct MomentRankerTests {

    private func block(_ index: Int, _ start: Double, _ text: String, chapterIndex: Int? = nil) -> TranscriptBlock {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return TranscriptBlock(
            index: index,
            startSeconds: start,
            endSeconds: start + 10,
            text: text,
            wordCount: words,
            estimatedTokens: Int((Double(words) * 1.3).rounded()),
            chapterIndex: chapterIndex
        )
    }

    private func block(_ index: Int, _ start: Double, _ end: Double, _ text: String, chapterIndex: Int? = nil) -> TranscriptBlock {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return TranscriptBlock(
            index: index,
            startSeconds: start,
            endSeconds: end,
            text: text,
            wordCount: words,
            estimatedTokens: Int((Double(words) * 1.3).rounded()),
            chapterIndex: chapterIndex
        )
    }

    @Test("Ranks concrete insight windows above generic transcript")
    func ranksConcreteInsightWindows() {
        let blocks = [
            block(1, 0, "Welcome back. Today we are going to talk through a long project setup.", chapterIndex: 0),
            block(2, 10, "There are a few pieces and some background before the interesting part.", chapterIndex: 0),
            block(3, 20, "The key is that the local cache saves 42 percent of the cost because repeated transcript reads never hit the network.", chapterIndex: 1),
            block(4, 30, "This means the app feels instant instead of waiting several seconds for every query.", chapterIndex: 1),
            block(5, 40, "For example, the same search went from 9 seconds to 800 milliseconds in the demo.", chapterIndex: 1),
            block(6, 100, "The mistake was ranking every clip by density alone, because fast speech is not the same as an aha moment.", chapterIndex: 2),
            block(7, 110, "The result is better when quality passes first and diversity runs after that threshold.", chapterIndex: 2),
            block(8, 120, "Compared to the first prototype, the second one avoids duplicate cards about the same point.", chapterIndex: 2),
        ]
        let chapters = [
            VideoChapter(title: "Intro", startTime: 0, endTime: 20, estimatedTokens: nil),
            VideoChapter(title: "Cost advantage", startTime: 20, endTime: 100, estimatedTokens: nil),
            VideoChapter(title: "Ranking mistake", startTime: 100, endTime: 140, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Local video ranking cost advantage",
            description: "A demo about transcript ranking and local cache cost wins.",
            tags: ["ranking", "cache"],
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranking = MomentRanker.rank(result: result, config: MomentRankerConfig(limit: 2, includeCandidates: true))

        #expect(ranking.rankedMoments.count == 2)
        #expect(ranking.rankedMoments[0].cleanText.contains("42 percent") || ranking.rankedMoments[0].cleanText.contains("density alone"))
        #expect(ranking.rankedMoments[0].scoreBreakdown.insight > 0)
        #expect(ranking.rankedMoments[0].scoreBreakdown.concreteness > 0)
        #expect(ranking.rankedMoments[0].scoreBreakdown.mmrDiversity > 0)
        #expect(ranking.momentCandidates?.isEmpty == false)

        let first = ranking.rankedMoments[0]
        let second = ranking.rankedMoments[1]
        let overlap = max(0.0, min(first.endSeconds, second.endSeconds) - max(first.startSeconds, second.startSeconds))
        #expect(overlap == 0)
    }

    @Test("Empty transcript returns no moments")
    func emptyTranscriptReturnsNoMoments() {
        let result = SenseResult(url: "https://example.com/video", title: "No transcript")
        let ranking = MomentRanker.rank(result: result)
        #expect(ranking.rankedMoments.isEmpty)
    }

    @Test("SenseResult can attach and preserve rankedMoments through metadata-only shaping")
    func senseResultPreservesRankedMoments() {
        let block = block(1, 0, "The key is that a small local ranker can find 4 useful moments because the transcript already has timestamps.")
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Moments",
            transcriptSource: .manual,
            transcriptBlocks: [block],
            estimatedTokens: block.estimatedTokens
        )
        let ranked = MomentRanker.rankedMoments(for: result, limit: 1)
        let shaped = result.withRankedMoments(ranked).withEmptyBlocks()

        #expect(shaped.transcriptBlocks.isEmpty)
        #expect(shaped.rankedMoments?.count == 1)
        #expect(shaped.rankedMoments?.first?.cleanText.contains("small local ranker") == true)
    }

    @Test("Sliced results resolve chapter titles by time when chapterIndex is original")
    func slicedResultsResolveChapterTitleByTime() {
        let blocks = [
            block(1, 0, "Intro setup with no ranking claim.", chapterIndex: 0),
            block(2, 100, "The mistake was treating fast speech as an aha moment because density alone repeats the same point.", chapterIndex: 2),
            block(3, 110, "The result improves when the diversity pass runs after a quality threshold with concrete evidence.", chapterIndex: 2),
            block(4, 120, "Compared to the old heuristic, this keeps the best 4 cards distinct and self contained.", chapterIndex: 2),
        ]
        let chapters = [
            VideoChapter(title: "Intro", startTime: 0, endTime: 20, estimatedTokens: nil),
            VideoChapter(title: "Cost advantage", startTime: 20, endTime: 100, estimatedTokens: nil),
            VideoChapter(title: "Ranking mistake", startTime: 100, endTime: 140, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Ranking mistake",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let sliced = result.sliced(startSeconds: 100, endSeconds: 130)
        let ranked = MomentRanker.rankedMoments(for: sliced, limit: 1)

        #expect(sliced.chapters.count == 1)
        #expect(sliced.transcriptBlocks.first?.chapterIndex == 2)
        #expect(ranked.first?.chapterTitle == "Ranking mistake")
        #expect(ranked.first?.chapterIndex == 0)
    }

    @Test("CTA-heavy windows are penalized below useful claims")
    func ctaHeavyWindowsArePenalized() {
        let blocks = [
            block(1, 0, "Make sure to subscribe and click the subscribe button because most viewers are not subscribed.", chapterIndex: 0),
            block(2, 10, "Join the new society and learn in just three weeks from complete beginner to top 1% AI developer.", chapterIndex: 0),
            block(3, 100, "The key result is that the model is 40x cheaper while preserving 97 percent of the useful coding performance.", chapterIndex: 1),
            block(4, 110, "This means small automations can move to the cheaper model without changing the whole workflow.", chapterIndex: 1),
            block(5, 120, "Compared to the previous setup, the same agents cost pennies instead of dollars per run.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Subscribe", startTime: 0, endTime: 100, estimatedTokens: nil),
            VideoChapter(title: "Cost analysis", startTime: 100, endTime: 140, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Cost analysis",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranked = MomentRanker.rankedMoments(for: result, limit: 1)

        #expect(ranked.first?.chapterTitle == "Cost analysis")
        #expect(ranked.first?.cleanText.contains("40x cheaper") == true)
    }

    @Test("Sponsor reads are penalized below product insights")
    func sponsorReadsArePenalized() {
        let blocks = [
            block(1, 0, "Supporting sponsor Vanta helps over 15000 companies earn and prove trust with customers.", chapterIndex: 0),
            block(2, 10, "Go to works.com to make your app enterprise ready today with delightful APIs.", chapterIndex: 0),
            block(3, 100, "A lot of product changes happen when a new model removes features that were only crutches for model limitations.", chapterIndex: 1),
            block(4, 110, "The classic example is a to-do list because the newer model can keep the plan in its own context.", chapterIndex: 1),
            block(5, 120, "This means the product gets simpler as model intelligence improves instead of adding more UI.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Sponsor", startTime: 0, endTime: 100, estimatedTokens: nil),
            VideoChapter(title: "How new models force product changes", startTime: 100, endTime: 140, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Product changes",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranked = MomentRanker.rankedMoments(for: result, limit: 1)

        #expect(ranked.first?.chapterTitle == "How new models force product changes")
        #expect(ranked.first?.cleanText.contains("product gets simpler") == true)
    }

    @Test("Sponsor lead-ins are rejected even when mixed into real chapters")
    func sponsorLeadInsAreRejectedWhenMixedIntoRealChapters() {
        let blocks = [
            block(1, 0, "and prove trust with their customers. Teams are building and shipping products faster than ever thanks to AI.", chapterIndex: 0),
            block(2, 10, "Vanta automates compliance and risk management. Learn more at vanta.com/lenny and get 1000 off.", chapterIndex: 0),
            block(3, 30, "A lot of product changes happen when a new model removes features that were only crutches for model limitations.", chapterIndex: 0),
            block(4, 40, "The classic example is a to-do list because the newer model can keep the plan in its own context.", chapterIndex: 0),
            block(5, 50, "This means the product gets simpler as model intelligence improves instead of adding more UI.", chapterIndex: 0),
            block(6, 140, "The second insight is that PMs need to test model behavior with concrete examples before changing roadmaps.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Cat's PM tech stack and internal tools", startTime: 0, endTime: 120, estimatedTokens: nil),
            VideoChapter(title: "PM skills", startTime: 120, endTime: 180, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Product changes",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranked = MomentRanker.rankedMoments(for: result, limit: 1)

        #expect(ranked.first?.cleanText.contains("Vanta") == false)
        #expect(ranked.first?.cleanText.contains("product gets simpler") == true)
    }

    @Test("Intro sections are penalized below specific later moments")
    func introSectionsArePenalizedBelowSpecificLaterMoments() {
        let blocks = [
            block(1, 0, "Welcome back. Everyone says different things about this topic and it is a difficult question today.", chapterIndex: 0),
            block(2, 10, "I wanted to start with the basic definition before we get to the examples and decisions.", chapterIndex: 0),
            block(3, 100, "The key result is that the new workflow cuts review time by 35 percent because the model checks every pull request.", chapterIndex: 1),
            block(4, 110, "This means the team can find mistakes before merge instead of waiting for a production incident.", chapterIndex: 1),
            block(5, 120, "Compared to the old process, the same review took 12 minutes instead of 40 minutes in the demo.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Intro", startTime: 0, endTime: 80, estimatedTokens: nil),
            VideoChapter(title: "Review benchmark", startTime: 80, endTime: 150, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Review benchmark",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranked = MomentRanker.rankedMoments(for: result, limit: 1)

        #expect(ranked.first?.chapterTitle == "Review benchmark")
        #expect(ranked.first?.cleanText.contains("35 percent") == true)
    }

    @Test("Leading fragments are penalized below self-contained starts")
    func leadingFragmentsArePenalizedBelowSelfContainedStarts() {
        let blocks = [
            block(1, 0, "to be 40 percent cheaper than the baseline because the model reuses cached context.", chapterIndex: 0),
            block(2, 10, "This means teams can run the same automation more often without increasing spend.", chapterIndex: 0),
            block(3, 100, "The key result is that the model is 40 percent cheaper because it reuses cached context.", chapterIndex: 1),
            block(4, 110, "This means teams can run the same automation more often without increasing spend.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Fragmented cost note", startTime: 0, endTime: 80, estimatedTokens: nil),
            VideoChapter(title: "Self-contained cost result", startTime: 80, endTime: 140, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Cost result",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranked = MomentRanker.rankedMoments(for: result, limit: 1)

        #expect(ranked.first?.chapterTitle == "Self-contained cost result")
        #expect(ranked.first?.cleanText.hasPrefix("The key result") == true)
    }

    @Test("Overlapping caption lead-ins are expanded into the moment")
    func overlappingCaptionLeadInsAreExpanded() {
        let blocks = [
            block(1, 0, 2, "Welcome back. We are going to look at model benchmarks today.", chapterIndex: 0),
            block(2, 17, 19, "what you need to realize is that Deep Seek", chapterIndex: 1),
            block(3, 20, 22, "Deep Seek comes in two sizes. Deepseek V4 Pro and", chapterIndex: 1),
            block(4, 22, 24, "Deepseek V4 Pro and DeepSeek Flash are 40 percent cheaper because", chapterIndex: 1),
            block(5, 24, 26, "because cached context avoids repeated work for agents.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Intro", startTime: 0, endTime: 10, estimatedTokens: nil),
            VideoChapter(title: "Benchmark comparison", startTime: 10, endTime: 40, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Benchmark comparison",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranking = MomentRanker.rank(
            result: result,
            config: MomentRankerConfig(
                limit: 1,
                minDurationSeconds: 2,
                targetDurationSeconds: 4,
                maxDurationSeconds: 12,
                strideSeconds: 20,
                qualityThreshold: 0
            )
        )

        #expect(ranking.rankedMoments.first?.startSeconds == 17)
        #expect(ranking.rankedMoments.first?.cleanText.hasPrefix("what you need to realize") == true)
    }

    @Test("Incomplete caption endings are extended")
    func incompleteCaptionEndingsAreExtended() {
        let blocks = [
            block(1, 0, 2, "The key result is that the model is 40 percent cheaper because", chapterIndex: 0),
            block(2, 2, 4, "because cached context avoids repeated transcript work and", chapterIndex: 0),
            block(3, 4, 6, "and this means teams can run the agent every hour.", chapterIndex: 0),
        ]
        let chapters = [
            VideoChapter(title: "Cost result", startTime: 0, endTime: 20, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Cost result",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranking = MomentRanker.rank(
            result: result,
            config: MomentRankerConfig(
                limit: 1,
                minDurationSeconds: 2,
                targetDurationSeconds: 4,
                maxDurationSeconds: 10,
                strideSeconds: 20,
                qualityThreshold: 0
            )
        )

        #expect(ranking.rankedMoments.first?.endSeconds == 6)
        #expect(ranking.rankedMoments.first?.cleanText.contains("every hour.") == true)
    }

    @Test("Overlapping lead-ins can cross chapter boundaries")
    func overlappingLeadInsCanCrossChapterBoundaries() {
        let blocks = [
            block(1, 0, 2, "architecture itself. But the most interesting part is the hardware,", chapterIndex: 0),
            block(2, 2, 4, "part is the hardware, the GPUs. If you think about it, this", chapterIndex: 1),
            block(3, 4, 6, "the GPUs. If you think about it, this model is 40 percent cheaper because", chapterIndex: 1),
            block(4, 6, 8, "because it was not trained on the best hardware.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Architecture", startTime: 0, endTime: 2, estimatedTokens: nil),
            VideoChapter(title: "GPU story", startTime: 2, endTime: 20, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "GPU story",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranking = MomentRanker.rank(
            result: result,
            config: MomentRankerConfig(
                limit: 1,
                minDurationSeconds: 2,
                targetDurationSeconds: 4,
                maxDurationSeconds: 10,
                strideSeconds: 2,
                qualityThreshold: 0
            )
        )

        #expect(ranking.rankedMoments.first?.startSeconds == 0)
        #expect(ranking.rankedMoments.first?.cleanText.contains("the most interesting part is the hardware") == true)
    }

    @Test("Diversity penalizes repeated chapter picks")
    func diversityPenalizesRepeatedChapterPicks() {
        let blocks = [
            block(1, 0, "The key cost result is 40 percent cheaper because token caching removes repeated work.", chapterIndex: 0),
            block(2, 10, "This means one automation costs pennies instead of dollars and can run more often.", chapterIndex: 0),
            block(3, 100, "The key cost result is 35 percent cheaper because batching removes repeated work.", chapterIndex: 0),
            block(4, 110, "This means another automation costs pennies instead of dollars and can run more often.", chapterIndex: 0),
            block(5, 220, "The mistake in the old workflow was trusting long context after it starts degrading past 128k tokens.", chapterIndex: 1),
            block(6, 230, "This means the safer workflow is compaction before the model begins losing details.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Cost", startTime: 0, endTime: 200, estimatedTokens: nil),
            VideoChapter(title: "Context degradation", startTime: 200, endTime: 260, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Cost and context",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranked = MomentRanker.rankedMoments(for: result, limit: 2)

        #expect(Set(ranked.compactMap(\.chapterTitle)).count == 2)
    }
}
