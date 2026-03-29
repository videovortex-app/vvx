import ArgumentParser
import Hummingbird
import VideoVortexCore

// Entry point for the vvx-serve Local Agent API.
// Usage: vvx-serve [--port 8080] [--token <bearer-token>]
//
// Starts a localhost HTTP server that gives LLM agents structured
// access to VideoVortex download, library, and search capabilities.
//
// Endpoints:
//   POST /ingest          — queue a download, returns taskId
//   GET  /status/{taskId} — poll completion status + VideoMetadata
//   GET  /library         — list all downloaded media as VideoMetadata[]
//   POST /search          — full-text search across .srt transcripts
//   POST /export          — zip archive folder(s) for agent consumption

@main
struct VvxServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vvx-serve",
        abstract: "VideoVortex Local Agent API — video intelligence for LLM agents."
    )

    @Option(name: .shortAndLong, help: "Port to listen on.")
    var port: Int = 8080

    @Option(name: .long, help: "Bearer token for auth (generated on first run if omitted).")
    var token: String?

    mutating func run() async throws {
        VvxLogging.bootstrap()
        let server = AgentServer(port: port, token: token)
        try await server.start()
    }
}
