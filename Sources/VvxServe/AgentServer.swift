import Foundation
import Hummingbird
import VideoVortexCore

/// The Local Agent API server.
///
/// Endpoints:
///   GET  /health               — unauthenticated health check
///   POST /ingest               — queue downloads, returns taskId[]
///   GET  /status/{taskId}      — poll task progress + VideoMetadata on completion
///   GET  /library              — list all downloaded media as VideoMetadata[]
///   POST /search               — full-text search across .srt transcripts
///   POST /export               — zip archive folders for agent consumption
///
/// All endpoints except /health require Authorization: Bearer <token>.
/// Token is stored in ~/.vvx/server-token (auto-generated on first run).
struct AgentServer {
    let port: Int
    let tokenOverride: String?

    init(port: Int, token: String?) {
        self.port = port
        self.tokenOverride = token
    }

    func start() async throws {
        let token     = tokenOverride ?? ServerToken.loadOrCreate()
        let taskStore = TaskStore()
        let resolver  = EngineResolver.cliResolver

        let router = Router()

        // MARK: Health (unauthenticated)
        router.get("/health") { _, _ in
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(string: #"{"status":"ok","server":"vvx-serve"}"#))
            )
        }

        // MARK: Authenticated routes
        let api = router.group()
            .add(middleware: BearerAuthMiddleware(expectedToken: token))

        // POST /ingest
        api.post("/ingest") { request, context in
            try await handleIngest(request: request, context: context, taskStore: taskStore, resolver: resolver)
        }

        // GET /status/{taskId}
        api.get("/status/:taskId") { request, context in
            let taskIdString = context.parameters.get("taskId") ?? ""
            return try await handleStatus(taskIdString: taskIdString, taskStore: taskStore)
        }

        // GET /library
        api.get("/library") { request, context in
            try await handleLibrary(request: request, context: context)
        }

        // POST /search
        api.post("/search") { request, context in
            try await handleSearch(request: request, context: context)
        }

        // POST /export
        api.post("/export") { request, context in
            try await handleExport(request: request, context: context)
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port))
        )

        print("vvx-serve listening on http://127.0.0.1:\(port)")
        print("Bearer token: \(token)")
        print("Token stored at: ~/.vvx/server-token")
        print("")
        print("Agent usage:")
        print("  curl -H 'Authorization: Bearer \(token)' http://127.0.0.1:\(port)/health")
        print("  curl -X POST -H 'Authorization: Bearer \(token)' -d '{\"urls\":[\"...\"]}'  http://127.0.0.1:\(port)/ingest")
        print("")

        try await app.runService()
    }
}
