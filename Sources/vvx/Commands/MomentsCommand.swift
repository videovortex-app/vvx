import ArgumentParser
import Foundation
import VideoVortexCore

struct MomentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "moments",
        abstract: "Rank the best local transcript moments from a saved sense JSON.",
        discussion: """
        Development/eval surface for MomentRanker.

        Product path:
          vvx sense <url> --moments --moment-limit 10

        Debug/eval path:
          vvx moments --from-sense result.json --limit 10 --explain

        This command does not search the archive, gather clips, or call an LLM.
        It maps one transcript to ranked moments.
        """
    )

    @Option(name: .customLong("from-sense"), help: "Path to a SenseResult JSON file produced by vvx sense.")
    var fromSense: String

    @Option(name: .long, help: "Maximum ranked moments to return. Default: 10.")
    var limit: Int = 10

    @Flag(name: .long, help: "Include debug momentCandidates before the MMR diversity pass.")
    var explain: Bool = false

    mutating func run() async throws {
        guard limit > 0 else {
            printError(code: .parseError, message: "--limit must be > 0.")
            throw ExitCode(VvxExitCode.userError)
        }

        let path = (fromSense as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            printError(code: .permissionDenied,
                       message: "Could not read --from-sense file: \(error.localizedDescription)")
            throw ExitCode(VvxExitCode.diskPermission)
        }

        let result: SenseResult
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            result = try decoder.decode(SenseResult.self, from: data)
        } catch {
            printError(code: .parseError,
                       message: "Could not decode SenseResult JSON: \(error.localizedDescription)")
            throw ExitCode(VvxExitCode.userError)
        }

        guard !result.transcriptBlocks.isEmpty else {
            printError(code: .parseError,
                       message: "SenseResult has no transcriptBlocks. Re-run vvx sense without --metadata-only, then retry moments.")
            throw ExitCode(VvxExitCode.userError)
        }

        let ranking = MomentRanker.rank(
            result: result,
            config: MomentRankerConfig(limit: limit, includeCandidates: explain)
        )
        print(ranking.jsonString())
    }
}

private func printError(code: VvxErrorCode, message: String) {
    print(VvxErrorEnvelope(error: VvxError(code: code, message: message)).jsonString())
}
