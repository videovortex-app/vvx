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
}
