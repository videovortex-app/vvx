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

    @Test("Anchor-first ranking exposes payoff sentence debug fields")
    func anchorFirstRankingExposesPayoffDebugFields() {
        let blocks = [
            block(1, 0, 6, "First click install and then open the setup screen for the demo.", chapterIndex: 0),
            block(2, 6, 12, "Next download the starter files and step through each config option.", chapterIndex: 0),
            block(3, 30, 38, "The useful context is that teams were waiting seven days for release review.", chapterIndex: 1),
            block(4, 38, 46, "This means the release loop drops from 7 days to 2 hours because the model catches mistakes before humans review them.", chapterIndex: 1),
            block(5, 46, 54, "Instead of adding more process, the team ships small changes with the same safety.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Setup", startTime: 0, endTime: 20, estimatedTokens: nil),
            VideoChapter(title: "Release loop benchmark", startTime: 20, endTime: 70, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Release loop benchmark",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranking = MomentRanker.rank(
            result: result,
            config: MomentRankerConfig(
                limit: 1,
                includeCandidates: true,
                minDurationSeconds: 6,
                targetDurationSeconds: 18,
                maxDurationSeconds: 28,
                qualityThreshold: 0
            )
        )

        let first = ranking.rankedMoments.first
        #expect(first?.cleanText.contains("7 days to 2 hours") == true)
        #expect(first?.cleanText.contains("click install") == false)
        #expect(first?.centerSentence?.contains("7 days to 2 hours") == true)
        #expect((first?.anchorScore ?? 0) > 20)
        #expect((first?.anchorBreakdown?.consequence ?? 0) > 0)
        #expect((first?.anchorBreakdown?.concrete ?? 0) > 0)
        #expect(ranking.momentCandidates?.first?.centerSentence != nil)
    }

    @Test("V8 gates reject question anchors and unaligned numbers")
    func v8GatesRejectQuestionAnchorsAndUnalignedNumbers() {
        let blocks = [
            block(1, 0, 8, "What are the biggest bottlenecks when you look today?", chapterIndex: 0),
            block(2, 8, 16, "How do they go from like how do they make a similar thing?", chapterIndex: 0),
            block(3, 40, 48, "I heard in Tennessee that they make them at 11 percent alcohol but in Ohio we can only get 7 percent.", chapterIndex: 1),
            block(4, 80, 88, "This means DeepSeek is 40x cheaper because cached tokens reduce the cost of running parallel coding agents.", chapterIndex: 2),
            block(5, 88, 96, "Instead of spending dollars on each run, the workflow costs pennies and lets teams test more ideas.", chapterIndex: 2),
        ]
        let chapters = [
            VideoChapter(title: "Interview setup", startTime: 0, endTime: 30, estimatedTokens: nil),
            VideoChapter(title: "Anecdote", startTime: 30, endTime: 70, estimatedTokens: nil),
            VideoChapter(title: "Pricing: 40x Cheaper", startTime: 70, endTime: 110, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "DeepSeek pricing cost analysis",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranking = MomentRanker.rank(
            result: result,
            config: MomentRankerConfig(
                limit: 4,
                includeCandidates: true,
                minDurationSeconds: 6,
                targetDurationSeconds: 18,
                maxDurationSeconds: 28
            )
        )

        #expect(ranking.rankedMoments.count == 1)
        let first = ranking.rankedMoments.first
        #expect(first?.cleanText.contains("40x cheaper") == true)
        #expect(first?.cleanText.contains("11 percent alcohol") == false)
        #expect(first?.centerSentence?.hasSuffix("?") == false)
        #expect(first?.hasConsequenceNearby == true)
        #expect(first?.selectedForProduct == true)
        #expect((first?.wouldUserClickScore ?? 0) >= 75)

        let rejectionReasons = Set(ranking.rejectedAnchors?.map(\.rejectionReason) ?? [])
        #expect(rejectionReasons.contains("question_anchor"))
        #expect(rejectionReasons.contains("interviewer_setup"))
    }

    @Test("V8 click-worthiness rejects setup sponsor and vague rules")
    func v8ClickWorthinessRejectsSetupSponsorAndVagueRules() {
        let blocks = [
            block(1, 0, 8, "You mentioned the new Cursor 2.0 launch and talk about why people should care.", chapterIndex: 0),
            block(2, 8, 16, "Dream Team sent us a box of goodies with green tea and 11 ingredients for this episode.", chapterIndex: 0),
            block(3, 16, 24, "You have to like something has to be right because it changes things.", chapterIndex: 0),
            block(4, 60, 68, "The common mistake is accepting AI generated code without tests because silent failures ship to production.", chapterIndex: 1),
            block(5, 68, 76, "The fix is to run evals after each agent change and compare the output before merging.", chapterIndex: 1),
            block(6, 76, 84, "This means beginners can trust the workflow because every edit has a measurable safety check.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Intro", startTime: 0, endTime: 50, estimatedTokens: nil),
            VideoChapter(title: "Common mistake and eval fix", startTime: 50, endTime: 100, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Cursor AI beginner tutorial",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranking = MomentRanker.rank(
            result: result,
            config: MomentRankerConfig(
                limit: 3,
                includeCandidates: true,
                minDurationSeconds: 6,
                targetDurationSeconds: 20,
                maxDurationSeconds: 34
            )
        )

        let first = ranking.rankedMoments.first
        #expect(first?.chapterTitle == "Common mistake and eval fix")
        #expect(first?.cleanText.contains("run evals") == true)
        #expect(first?.cleanText.contains("Dream Team") == false)
        #expect(first?.cleanText.contains("something has to be right") == false)
        #expect(first?.contentMode == "tutorial/how-to")
        #expect(first?.selectedForProduct == true)
        #expect(first?.sponsorDetected == false)
        #expect(first?.usefulnessSignals?.contains("actionable_instruction") == true)
    }

    @Test("V9 caps native ad reads and keeps product moments")
    func v9CapsNativeAdReadsAndKeepsProductMoments() {
        let blocks = [
            block(1, 0, 8, "Let me break this down. In just eight weeks, I've seen a serious shift.", chapterIndex: 0),
            block(2, 8, 16, "The reason, FitScript. They ran 124 biomarkers and built a custom plan for energy.", chapterIndex: 0),
            block(3, 40, 48, "The key lesson is that pricing pages convert better when the promise is specific because buyers can compare value immediately.", chapterIndex: 1),
            block(4, 48, 56, "This means the team should test one concrete offer before adding more funnels or channels.", chapterIndex: 1),
            block(5, 56, 64, "Compared to the old page, the new offer made the next action obvious.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Personal update", startTime: 0, endTime: 30, estimatedTokens: nil),
            VideoChapter(title: "Pricing lesson", startTime: 30, endTime: 80, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Pricing growth lesson",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranking = MomentRanker.rank(
            result: result,
            config: MomentRankerConfig(
                limit: 2,
                includeCandidates: true,
                minDurationSeconds: 6,
                targetDurationSeconds: 20,
                maxDurationSeconds: 34
            )
        )

        let first = ranking.rankedMoments.first
        #expect(first?.cleanText.contains("pricing pages convert") == true)
        #expect(first?.cleanText.contains("FitScript") == false)
        #expect(first?.selectedForProduct == true)
        #expect((first?.clickScoreFinal ?? 0) >= 75)

        let rejectionReasons = Set(ranking.rejectedAnchors?.map(\.rejectionReason) ?? [])
        #expect(rejectionReasons.contains("sponsor_or_cta"))
    }

    @Test("V9 trims conversational handoff edges")
    func v9TrimsConversationalHandoffEdges() {
        let blocks = [
            block(1, 0, 8, "Dave, thoughts on this one?", chapterIndex: 0),
            block(2, 8, 16, "The key lesson is that shipping compounds because every small release teaches the team what customers actually use.", chapterIndex: 0),
            block(3, 16, 24, "This means weekly launches beat quarterly launches when the market is changing quickly.", chapterIndex: 0),
            block(4, 24, 32, "Compared to waiting for the perfect launch, the faster loop finds bad assumptions before they become expensive.", chapterIndex: 0),
        ]
        let chapters = [
            VideoChapter(title: "Shipping cadence lesson", startTime: 0, endTime: 50, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Shipping cadence lesson",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranked = MomentRanker.rankedMoments(
            for: result,
            limit: 1
        )

        #expect(ranked.first?.startSeconds == 8)
        #expect(ranked.first?.cleanText.contains("Dave, thoughts") == false)
        #expect(ranked.first?.cleanText.hasPrefix("The key lesson") == true)
        #expect(ranked.first?.selectedForProduct == true)
    }

    @Test("V10 cleans quote artifacts and dangling window starts")
    func v10CleansQuoteArtifactsAndDanglingWindowStarts() {
        let blocks = [
            block(1, 0, 8, #"It really is because I think this is the fundamental setup."#, chapterIndex: 0),
            block(2, 8, 16, #"I need to take some time and propose a plan anyways. " is even though we were not on plan mode."#, chapterIndex: 0),
            block(3, 16, 24, #"The key lesson is that Cursor plans should be pruned because removing 3 extra features cuts build time by 40 percent."#, chapterIndex: 0),
            block(4, 24, 32, #"This means the product gets simpler instead of adding more UI that the user never asked for."#, chapterIndex: 0),
        ]
        let chapters = [
            VideoChapter(title: "Cursor planning lesson", startTime: 0, endTime: 50, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Cursor planning lesson",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranked = MomentRanker.rankedMoments(for: result, limit: 1)
        let text = ranked.first?.cleanText ?? ""

        #expect(text.hasPrefix("\"") == false)
        #expect(text.hasPrefix("It really is") == false)
        #expect(text.contains(#"" is even though"#) == false)
        #expect(text.contains("Cursor plans should be pruned") == true)
    }

    @Test("V10 rejects conference administration as meta fluff")
    func v10RejectsConferenceAdministrationAsMetaFluff() {
        let blocks = [
            block(1, 0, 8, "See the keynote after me for more info on that.", chapterIndex: 0),
            block(2, 20, 28, "The key lesson is that clankers can help write code but should not make product decisions for you.", chapterIndex: 1),
            block(3, 28, 36, "This means teams should keep humans in the decision loop because copied internet code carries old assumptions.", chapterIndex: 1),
            block(4, 36, 44, "Compared to trusting every generated patch, this keeps the system simpler and easier to debug.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Live event intro", startTime: 0, endTime: 15, estimatedTokens: nil),
            VideoChapter(title: "Clanker decision boundary", startTime: 15, endTime: 60, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Building agents in a world of slop",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranking = MomentRanker.rank(
            result: result,
            config: MomentRankerConfig(
                limit: 2,
                includeCandidates: true,
                minDurationSeconds: 6,
                targetDurationSeconds: 20,
                maxDurationSeconds: 34
            )
        )

        #expect(ranking.rankedMoments.first?.cleanText.contains("keynote after me") == false)
        #expect(ranking.rankedMoments.first?.cleanText.contains("should not make product decisions") == true)

        let rejectionReasons = Set(ranking.rejectedAnchors?.map(\.rejectionReason) ?? [])
        #expect(rejectionReasons.contains("podcast_or_admin_fluff"))
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

    @Test("Overlapping caption lead-ins snap to the payoff")
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
            VideoChapter(title: "Deepseek benchmark comparison", startTime: 10, endTime: 40, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Deepseek benchmark comparison",
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

        #expect(ranking.rankedMoments.first?.startSeconds == 20)
        #expect(ranking.rankedMoments.first?.cleanText.hasPrefix("Deepseek V4 Pro") == true)
        #expect(ranking.rankedMoments.first?.cleanText.contains("40 percent cheaper") == true)
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

        #expect(ranking.rankedMoments.first?.startSeconds == 2)
        #expect(ranking.rankedMoments.first?.cleanText.hasPrefix("If you think about it") == true)
        #expect(ranking.rankedMoments.first?.cleanText.contains("40 percent cheaper") == true)
    }

    @Test("Broad regions compress around the payoff")
    func broadRegionsCompressAroundPayoff() {
        let blocks = [
            block(1, 0, 10, "Welcome back. We are going to slowly set up the context for this example.", chapterIndex: 0),
            block(2, 10, 20, "The background is useful but it is not yet the actual moment worth showing.", chapterIndex: 0),
            block(3, 20, 30, "The key result is that the workflow is 42 percent cheaper because cached transcript reads avoid network calls.", chapterIndex: 0),
            block(4, 30, 40, "This means the same automation can run every hour instead of once a day without increasing spend.", chapterIndex: 0),
            block(5, 40, 50, "Compared to the old process, the team gets fresher context and lower cost at the same time.", chapterIndex: 0),
            block(6, 50, 60, "After that there are some implementation details that are useful but less important.", chapterIndex: 0),
            block(7, 60, 70, "Why? It's not because we", chapterIndex: 0),
        ]
        let chapters = [
            VideoChapter(title: "Cost result", startTime: 0, endTime: 80, estimatedTokens: nil),
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

        #expect(ranked.first?.durationSeconds ?? 99 <= 56)
        #expect(ranked.first?.cleanText.contains("Welcome back") == false)
        #expect(ranked.first?.cleanText.contains("42 percent cheaper") == true)
        #expect(ranked.first?.cleanText.contains("Why? It's not because we") == false)
    }

    @Test("Speaker markers and repeated words are scrubbed")
    func speakerMarkersAndRepeatedWordsAreScrubbed() {
        let blocks = [
            block(1, 0, 10, ">> The key result is that I I can cut review time by 35 percent because the model checks every pull request.", chapterIndex: 0),
            block(2, 10, 20, "This means the team can find mistakes before merge instead of waiting for production.", chapterIndex: 0),
            block(3, 20, 30, "Compared to the old process, the same review takes 12 minutes instead of 40 minutes.", chapterIndex: 0),
        ]
        let chapters = [
            VideoChapter(title: "Review benchmark", startTime: 0, endTime: 40, estimatedTokens: nil),
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

        #expect(ranked.first?.cleanText.contains(">>") == false)
        #expect(ranked.first?.cleanText.contains("I I") == false)
        #expect(ranked.first?.cleanText.contains("I can cut review time") == true)
    }

    @Test("Leading false starts and dangling trailing fragments are scrubbed")
    func leadingFalseStartsAndDanglingTrailingFragmentsAreScrubbed() {
        let blocks = [
            block(1, 0, 10, "we I mean the key lesson is that AI tools now find multi chain exploits faster than teams expect.", chapterIndex: 0),
            block(2, 10, 20, "This means security work has to move from annual audits to continuous review because the attack surface changes every day.", chapterIndex: 0),
            block(3, 20, 30, "Compared to the old process, the same team can catch 30 percent more issues before release.", chapterIndex: 0),
            block(4, 30, 40, "and I think we've basically helped put together all the talent from", chapterIndex: 0),
        ]
        let chapters = [
            VideoChapter(title: "Security shift", startTime: 0, endTime: 50, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Security shift",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let ranked = MomentRanker.rankedMoments(for: result, limit: 1)
        let text = ranked.first?.cleanText ?? ""

        #expect(text.contains("security work has to move") == true)
        #expect(text.contains("and I think") == false)
        #expect(text.hasSuffix("from") == false)
    }

    @Test("Diversity penalizes repeated chapter picks")
    func diversityPenalizesRepeatedChapterPicks() {
        let blocks = [
            block(1, 0, "The key cost result is 40 percent cheaper because token caching removes repeated work.", chapterIndex: 0),
            block(2, 10, "This means one automation costs pennies instead of dollars and can run more often.", chapterIndex: 0),
            block(3, 100, "The key cost result is 35 percent cheaper because batching removes repeated work.", chapterIndex: 0),
            block(4, 110, "This means another automation costs pennies instead of dollars and can run more often.", chapterIndex: 0),
            block(5, 220, "The key lesson is that trusting long context after 128k tokens is a mistake because the model starts losing details.", chapterIndex: 1),
            block(6, 230, "This means the safer workflow is compaction before decisions, compared to letting the agent drift silently.", chapterIndex: 1),
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

    @Test("Query moments search the full transcript instead of global top moments")
    func queryMomentsSearchFullTranscript() {
        let blocks = [
            block(1, 0, 8, "The key cost result is 40 percent cheaper because token caching removes repeated work.", chapterIndex: 0),
            block(2, 8, 16, "This means one automation costs pennies instead of dollars and can run more often.", chapterIndex: 0),
            block(3, 16, 24, "Compared to the old process, the team saves hours on every review.", chapterIndex: 0),
            block(4, 90, 98, "The panel moved through a few unrelated notes before the next topic.", chapterIndex: 1),
            block(5, 120, 128, "Local AI matters because private customer data can stay on the laptop instead of leaving the company.", chapterIndex: 2),
            block(6, 128, 136, "This means teams can test sensitive workflows without paying network latency or token costs on every draft.", chapterIndex: 2),
            block(7, 136, 144, "The tradeoff is weaker model quality, but the decision rule is to keep confidential work local first.", chapterIndex: 2),
        ]
        let chapters = [
            VideoChapter(title: "Cost benchmark", startTime: 0, endTime: 60, estimatedTokens: nil),
            VideoChapter(title: "Transition", startTime: 60, endTime: 110, estimatedTokens: nil),
            VideoChapter(title: "Local AI privacy", startTime: 110, endTime: 160, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://youtube.com/watch?v=querytest",
            title: "Automation cost and private local AI workflows",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let global = MomentRanker.rankedMoments(for: result, limit: 1)
        let query = MomentRanker.rankQuery(
            result: result,
            query: "local AI",
            config: MomentRankerConfig(limit: 2, includeCandidates: true, minDurationSeconds: 6, targetDurationSeconds: 18, maxDurationSeconds: 32)
        )

        #expect(global.first?.cleanText.contains("40 percent") == true)
        #expect(query.rankedMoments.first?.cleanText.contains("Local AI") == true)
        #expect((query.rankedMoments.first?.startSeconds ?? 0) >= 110)
        #expect(query.rankedMoments.first?.matchedTerms?.contains("local") == true)
        #expect(query.rankedMoments.first?.matchedTerms?.contains("ai") == true)
        #expect((query.rankedMoments.first?.queryMatchScore ?? 0) >= 70)
        #expect(query.rankedMoments.first?.videoURLAtTime?.contains("t=120s") == true)
        #expect(query.rankedMoments.first?.queryEvidence?.matchSentence.contains("Local AI matters") == true)
        #expect(query.rankedMoments.first?.queryEvidence?.highlightRanges.isEmpty == false)
        #expect(global.first?.queryEvidence == nil)
        #expect(query.queryCandidates?.isEmpty == false)
    }

    @Test("Query evidence makes late matched sentence the display focus")
    func queryEvidenceUsesMatchedSentenceInsteadOfContextPrefix() {
        let blocks = [
            block(1, 0, 8, "Imagine you are a CEO choosing between models for a customer support app.", chapterIndex: 0),
            block(2, 8, 16, "GPT 5.5 is $30 per million output tokens because teams pay for every generated answer.", chapterIndex: 0),
            block(3, 16, 24, "This matters because a million token run becomes real spend when agents loop all day.", chapterIndex: 0),
        ]
        let result = SenseResult(
            url: "https://www.youtube.com/watch?v=price&t=1176s",
            title: "Model pricing comparison",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +)
        )

        let query = MomentRanker.rankQuery(
            result: result,
            query: "million",
            config: MomentRankerConfig(limit: 2, includeCandidates: true, minDurationSeconds: 6, targetDurationSeconds: 24, maxDurationSeconds: 40)
        )

        let first = query.rankedMoments.first
        #expect(first?.selectedForProduct == true)
        #expect(first?.cleanText.hasPrefix("Imagine you are a CEO") == true)
        #expect(first?.queryEvidence?.matchSentence.contains("million") == true)
        #expect(first?.queryEvidence?.matchSentence.hasPrefix("Imagine you are a CEO") == false)
        #expect(first?.queryEvidence?.displayTitle == "$30 per million output tokens")
        #expect(first?.queryEvidence?.matchedTerms == ["million"])
        #expect(first?.queryEvidence?.highlightRanges.contains(where: { $0.term == "million" }) == true)
        #expect((first?.queryEvidence?.matchStartSeconds ?? 0) >= 8)
        #expect(first?.queryEvidence?.urlAtMatch?.contains("t=1176s") == false)
        #expect(first?.queryEvidence?.urlAtMatch?.contains("t=8s") == true)
        #expect(first?.videoURLAtTime?.contains("t=1176s") == false)
    }

    @Test("Query evidence rejects malformed numeric titles")
    func queryEvidenceRejectsMalformedNumericTitles() {
        let blocks = [
            block(1, 0, 8, "This is the report from Anthropic about model distillation.", chapterIndex: 0),
            block(2, 8, 16, "The scale of Deep Seek's distillation attack is just 150,000 exchanges.", chapterIndex: 0),
            block(3, 16, 24, "Moonshot, the company behind Kimmy, had 3.4 4 million and Miniax has 13 million.", chapterIndex: 0),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Distillation report",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +)
        )

        let query = MomentRanker.rankQuery(
            result: result,
            query: "million",
            config: MomentRankerConfig(limit: 2, includeCandidates: true, minDurationSeconds: 6, targetDurationSeconds: 24, maxDurationSeconds: 40)
        )

        let evidence = query.rankedMoments.first?.queryEvidence
        #expect(evidence?.matchSentence.contains("3.4 4 million") == true)
        #expect(evidence?.displayTitle != "3.4 4 million")
        #expect(evidence?.displayTitle == "Moonshot and Miniax exchange counts")
        #expect(evidence?.highlightRanges.count == 2)
    }

    @Test("Query moments return empty result with reason when no query match exists")
    func queryMomentsReturnEmptyForNoMatch() {
        let blocks = [
            block(1, 0, "The key cost result is cheaper because token caching removes repeated work.", chapterIndex: 0),
            block(2, 10, "This means one automation costs pennies instead of dollars and can run more often.", chapterIndex: 0),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Cost benchmark",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +)
        )

        let query = MomentRanker.rankQuery(
            result: result,
            query: "volcano ash",
            config: MomentRankerConfig(limit: 3, includeCandidates: true)
        )

        #expect(query.rankedMoments.isEmpty)
        #expect(query.noResultReason == "no_query_match")
        #expect(query.queryStrength == .weak)
        #expect(query.queryCandidates?.isEmpty == true)
    }

    @Test("Query moments dedupe overlapping query windows")
    func queryMomentsDedupeOverlappingWindows() {
        let blocks = [
            block(1, 0, 8, "Local AI matters because private data can stay on the laptop.", chapterIndex: 0),
            block(2, 8, 16, "Local AI also cuts latency because the workflow does not wait on a remote API.", chapterIndex: 0),
            block(3, 16, 24, "This means sensitive drafts can be tested quickly before anything leaves the company.", chapterIndex: 0),
            block(4, 90, 98, "A separate local AI lesson is that smaller models are cheaper but need tighter evals.", chapterIndex: 1),
            block(5, 98, 106, "The decision rule is to run local first, then escalate only when quality fails.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Local privacy", startTime: 0, endTime: 60, estimatedTokens: nil),
            VideoChapter(title: "Local evals", startTime: 80, endTime: 130, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Local AI workflows",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let query = MomentRanker.rankQuery(
            result: result,
            query: "local AI",
            config: MomentRankerConfig(limit: 3, includeCandidates: true, minDurationSeconds: 6, targetDurationSeconds: 18, maxDurationSeconds: 32)
        )

        #expect(query.rankedMoments.count == 2)
        #expect(query.dedupedOverlaps?.isEmpty == false)
        let first = query.rankedMoments[0]
        let second = query.rankedMoments[1]
        let overlap = max(0.0, min(first.endSeconds, second.endSeconds) - max(first.startSeconds, second.startSeconds))
        #expect(overlap == 0)
    }

    @Test("Query moments reject sponsor matches instead of forcing a result")
    func queryMomentsRejectSponsorMatches() {
        let blocks = [
            block(1, 0, 8, "Let me break this down. In just eight weeks, I've seen a serious shift.", chapterIndex: 0),
            block(2, 8, 16, "The reason, Fit Script. They ran 124 biomarkers and gave me a plan.", chapterIndex: 0),
            block(3, 60, 68, "The real lesson is that product teams should validate retention before scaling spend.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Sponsor", startTime: 0, endTime: 30, estimatedTokens: nil),
            VideoChapter(title: "Retention lesson", startTime: 50, endTime: 90, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Retention lessons",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let query = MomentRanker.rankQuery(
            result: result,
            query: "Fit Script",
            config: MomentRankerConfig(limit: 3, includeCandidates: true, minDurationSeconds: 6, targetDurationSeconds: 18, maxDurationSeconds: 32)
        )

        #expect(query.rankedMoments.isEmpty)
        #expect(query.noResultReason == "no_useful_query_moment")
        #expect(query.rejectedQueryAnchors?.contains(where: { $0.rejectionReason == "sponsor_or_cta" || $0.rejectionReason == "sponsor_or_admin_meta" }) == true)
    }

    @Test("Query moments support single-keyword searches")
    func queryMomentsSupportSingleKeywordSearches() {
        let blocks = [
            block(1, 0, 8, "Firecrawl matters because it turns messy websites into clean markdown for agents.", chapterIndex: 0),
            block(2, 8, 16, "This means the crawler can feed reliable pages into evals instead of brittle scraping.", chapterIndex: 0),
            block(3, 60, 68, "A separate point is that model quality still needs measurement.", chapterIndex: 1),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Firecrawl agent workflows",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +)
        )

        let query = MomentRanker.rankQuery(
            result: result,
            query: "Firecrawl",
            config: MomentRankerConfig(limit: 3, includeCandidates: true, minDurationSeconds: 6, targetDurationSeconds: 18, maxDurationSeconds: 32)
        )

        #expect(query.rankedMoments.isEmpty == false)
        #expect(query.rankedMoments.first?.matchedTerms?.contains("firecrawl") == true)
        #expect((query.rankedMoments.first?.queryMatchScore ?? 0) >= 30)
        #expect(query.rankedMoments.first?.whySelected.contains("shows query consequence") == true)
    }

    @Test("Query moments apply query floor before global quality can rescue weak matches")
    func queryMomentsApplyQueryFloor() {
        let blocks = [
            block(1, 0, 8, "Software matters because teams can ship safely when release checks catch mistakes.", chapterIndex: 0),
            block(2, 8, 16, "This means the workflow saves days and reduces failed deploys.", chapterIndex: 0),
            block(3, 60, 68, "Agents are mentioned briefly in the intro with no useful detail.", chapterIndex: 1),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Release workflow",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +)
        )

        let query = MomentRanker.rankQuery(
            result: result,
            query: "software agents",
            config: MomentRankerConfig(limit: 3, includeCandidates: true, minDurationSeconds: 6, targetDurationSeconds: 18, maxDurationSeconds: 32)
        )

        #expect(query.rankedMoments.isEmpty)
        #expect(query.noResultReason == "no_useful_query_moment")
        #expect(query.rejectedQueryAnchors?.contains(where: { $0.rejectionReason == "below_query_floor" }) == true)
    }

    @Test("Query moments prefer concise payoff over run-on exact phrase")
    func queryMomentsPreferConcisePayoffOverRunOnExactPhrase() {
        let longRant = "Simplify business is what you want to do when everything gets complicated and you want to simplify business in order to have that one one one when you're in it though you're tied into every nuance because if I tell you change that you say wait I have a story about the first company and the customer and the team and all the details that pull us away"
        let blocks = [
            block(1, 0, 12, longRant, chapterIndex: 0),
            block(2, 50, 58, "The real rule is to simplify business by cutting every product line that does not change retention.", chapterIndex: 1),
            block(3, 58, 66, "This matters because the team can then measure one customer promise instead of ten competing stories.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Messy story", startTime: 0, endTime: 30, estimatedTokens: nil),
            VideoChapter(title: "Simplify business rule", startTime: 40, endTime: 90, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Simplify business",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let query = MomentRanker.rankQuery(
            result: result,
            query: "simplify business",
            config: MomentRankerConfig(limit: 2, includeCandidates: true, minDurationSeconds: 6, targetDurationSeconds: 18, maxDurationSeconds: 32)
        )

        #expect(query.rankedMoments.first?.centerSentence?.contains("real rule") == true)
        #expect((query.rankedMoments.first?.momentQualityScore ?? 0) >= 55)
    }

    @Test("Query moments prepend context for dangling query centers")
    func queryMomentsPrependContextForDanglingCenters() {
        let blocks = [
            block(1, 0, 8, "The Obsidian CLI is the bridge between the vault and the agent.", chapterIndex: 0),
            block(2, 8, 16, "With the Obsidian CLI, it can give Claude Code not only files but relationships and backlinks.", chapterIndex: 0),
            block(3, 16, 24, "This matters because Claude Code can reason across notes instead of reading isolated markdown.", chapterIndex: 0),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Claude Code Obsidian workflow",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +)
        )

        let query = MomentRanker.rankQuery(
            result: result,
            query: "Claude Code Obsidian",
            config: MomentRankerConfig(limit: 2, includeCandidates: true, minDurationSeconds: 6, targetDurationSeconds: 18, maxDurationSeconds: 32)
        )

        let text = query.rankedMoments.first?.cleanText ?? ""
        #expect(text.hasPrefix("The Obsidian CLI is the bridge") == true)
        #expect(text.contains("it can give Claude Code") == true)
    }

    @Test("Query moments demote unresolved preposition pronoun anchors")
    func queryMomentsDemoteUnresolvedPrepositionPronounAnchors() {
        let blocks = [
            block(1, 0, 8, "With the Obsidian CLI, it can give Claude Code relationships and backlinks because the vault already has that graph.", chapterIndex: 0),
            block(2, 50, 58, "Claude Code and Obsidian work best when the vault stores decisions, projects, and daily notes together.", chapterIndex: 1),
            block(3, 58, 66, "This matters because the agent can explain why a note connects to a project instead of only reading isolated files.", chapterIndex: 1),
        ]
        let chapters = [
            VideoChapter(title: "Dangling setup", startTime: 0, endTime: 20, estimatedTokens: nil),
            VideoChapter(title: "Claude Code Obsidian payoff", startTime: 40, endTime: 90, estimatedTokens: nil),
        ]
        let result = SenseResult(
            url: "https://example.com/video",
            title: "Claude Code Obsidian workflow",
            transcriptSource: .manual,
            transcriptBlocks: blocks,
            estimatedTokens: blocks.map(\.estimatedTokens).reduce(0, +),
            chapters: chapters
        )

        let query = MomentRanker.rankQuery(
            result: result,
            query: "Claude Code Obsidian",
            config: MomentRankerConfig(limit: 2, includeCandidates: true, minDurationSeconds: 6, targetDurationSeconds: 18, maxDurationSeconds: 32)
        )

        #expect(query.rankedMoments.first?.cleanText.contains("work best") == true)
        #expect(query.rankedMoments.first?.selectedForProduct == true)
        #expect(query.queryCandidates?.contains(where: {
            $0.centerSentence?.hasPrefix("With the Obsidian CLI") == true
                && $0.selectedForProduct == false
        }) == true)
    }
}
