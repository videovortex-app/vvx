import Foundation
import Hummingbird

// MARK: - JSON response helpers shared across all route handlers

func jsonResponse<T: Encodable>(_ value: T) throws -> Response {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    return Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(bytes: data))
    )
}

func jsonError(status: HTTPResponse.Status, message: String) -> Response {
    struct ErrorBody: Encodable { let error: String }
    let body = (try? JSONEncoder().encode(ErrorBody(error: message))) ?? Data()
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(bytes: body))
    )
}
