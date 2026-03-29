import ArgumentParser
import VideoVortexCore

struct SniperCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sniper",
        abstract: "Watch the clipboard and auto-download every copied video URL."
    )

    @Option(name: .long, help: "Output format: best, 1080p, 720p, broll, mp3, reactionkit.")
    var format: String = "best"

    @Flag(name: .long, help: "Enable archive mode for all captured URLs.")
    var archive: Bool = false

    mutating func run() async throws {
        // TODO: implemented in Phase 7
        print("vvx sniper — not yet implemented. Coming in Phase 7.")
    }
}
