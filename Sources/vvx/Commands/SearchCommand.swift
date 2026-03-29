import ArgumentParser
import Foundation
import VideoVortexCore

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Full-text search across all indexed transcripts.",
        discussion: """
        Searches the local vortex.db FTS5 index for the given query and returns
        ranked results with timestamps, snippets, and 2-block context windows.

        Supports FTS5 query syntax: boolean operators (AND, OR, NOT), phrase search
        ("exact phrase"), and prefix search (intell*). Porter stemming is active by
        default — "run" matches "running", "AGI" matches "AGIs".

        Default output is JSON on stdout.  Use --rag for agent-optimized Markdown
        with per-hit attribution and ready-to-run vvx clip commands.

        Examples:
          vvx search "artificial general intelligence"
          vvx search "AGI" --limit 20
          vvx search "AI AND danger"
          vvx search "mars colonization" --platform YouTube
          vvx search "specific quote" --after 2025-01-01
          vvx search "interview" --uploader "Lex Fridman"
          vvx search "AGI" --rag
          vvx search "Apple" --rag --max-tokens 5000
        """
    )

    @Argument(help: "The search query. Supports FTS5 syntax: AND, OR, NOT, phrase, prefix*.")
    var query: String

    @Option(name: .long, help: "Maximum number of results to return (default: 50).")
    var limit: Int = 50

    @Option(name: .long, help: "Filter by platform, e.g. YouTube, TikTok, Twitter.")
    var platform: String?

    @Option(name: .long, help: "Only include results from videos uploaded on or after this date (YYYY-MM-DD).")
    var after: String?

    @Option(name: .long, help: "Filter by uploader or channel name (exact match).")
    var uploader: String?

    @Flag(name: .long, help: "Output agent-optimized Markdown with per-hit attribution and vvx clip commands. Recommended for RAG workflows.")
    var rag: Bool = false

    @Option(name: .long, help: "Maximum estimated tokens for --rag output. Truncates hits before exceeding this budget (token estimate: word count × 1.3). Requires --rag.")
    var maxTokens: Int?

    mutating func run() async throws {
        fputs("Searching vortex.db…\n", stderr)

        let db: VortexDB
        do {
            db = try VortexDB.open()
        } catch {
            let envelope = SearchErrorEnvelope(
                query:   query,
                message: "Could not open vortex.db: \(error.localizedDescription)"
            )
            print(envelope.jsonString())
            throw ExitCode(1)
        }

        let output: SearchOutput
        do {
            output = try await SRTSearcher.search(
                query:     query,
                db:        db,
                platform:  platform,
                afterDate: after,
                uploader:  uploader,
                limit:     limit
            )
        } catch {
            let envelope = SearchErrorEnvelope(
                query:   query,
                message: "Search failed: \(error.localizedDescription)"
            )
            print(envelope.jsonString())
            throw ExitCode(1)
        }

        fputs("Found \(output.totalMatches) result(s).\n", stderr)

        if rag {
            let markdown = SRTSearcher.ragMarkdown(
                query:              query,
                results:            output.results,
                totalBeforeBudget:  output.totalMatches,
                maxTokens:          maxTokens,
                versionString:      vvxDocsVersion
            )
            print(markdown)
        } else {
            print(output.jsonString())
        }
    }
}

// MARK: - Error envelope

/// Minimal failure envelope so agents always receive valid JSON from `vvx search`.
private struct SearchErrorEnvelope: Codable {
    var success: Bool
    var query: String
    var totalMatches: Int
    var results: [String]
    var error: String

    init(query: String, message: String) {
        self.success      = false
        self.query        = query
        self.totalMatches = 0
        self.results      = []
        self.error        = message
    }

    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let str  = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - Helpers

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
