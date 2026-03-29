import Foundation
import Hummingbird

/// Simple Bearer token middleware for the Local Agent API.
/// The token is stored in ~/.vvx/server-token.
/// Requests without a matching Authorization: Bearer <token> header receive 401.
struct BearerAuthMiddleware<Context: RequestContext>: RouterMiddleware {

    let expectedToken: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let authHeader = request.headers[.authorization],
              authHeader.hasPrefix("Bearer "),
              authHeader.dropFirst("Bearer ".count) == expectedToken
        else {
            return Response(
                status: .unauthorized,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(string: #"{"error":"Unauthorized — invalid or missing Bearer token."}"#))
            )
        }
        return try await next(request, context)
    }
}

// MARK: - Token persistence

enum ServerToken {

    private static let tokenFilePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".vvx/server-token").path

    /// Loads the stored token or generates a new one on first run.
    static func loadOrCreate() -> String {
        if let existing = try? String(contentsOfFile: tokenFilePath, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let newToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try? FileManager.default.createDirectory(
            atPath: (tokenFilePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? newToken.write(toFile: tokenFilePath, atomically: true, encoding: .utf8)
        return newToken
    }
}
