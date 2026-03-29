import Foundation
import VideoVortexCore

// MARK: - MCP Server

/// JSON-RPC 2.0 dispatcher for the vvx MCP server.
///
/// Reads requests from stdin one line at a time and writes JSON-RPC responses
/// exclusively to stdout. All internal logging goes to stderr.
///
/// stdout purity is enforced here: the ONLY place that writes to stdout is
/// `writeResponse(_:)`. Tool implementations must never call `print()`.
public actor McpServer {

    public static let shared = McpServer()

    private let registry = McpToolRegistry()

    // MARK: - Main loop

    public func run() async {
        log("vvx-mcp starting — waiting for requests on stdin")

        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                log("vvx-mcp: could not parse request: \(trimmed.prefix(200))")
                continue
            }

            if let response = await handle(json) {
                writeResponse(response)
            }
        }

        log("vvx-mcp: stdin closed — exiting")
    }

    // MARK: - Request dispatch

    private func handle(_ json: [String: Any]) async -> [String: Any]? {
        let method = json["method"] as? String ?? ""
        let id     = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        log("vvx-mcp: ← \(method)")

        switch method {

        case "initialize":
            return buildResponse(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "vvx", "version": "0.2.0"]
            ])

        case "initialized":
            // Notification — no response
            return nil

        case "ping":
            return buildResponse(id: id, result: [:])

        case "tools/list":
            return buildResponse(id: id, result: [
                "tools": registry.toolDefinitions()
            ])

        case "tools/call":
            let toolName  = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            log("vvx-mcp:   tool=\(toolName)")

            do {
                let content = try await registry.call(tool: toolName, arguments: arguments)
                return buildResponse(id: id, result: [
                    "content": [["type": "text", "text": content]]
                ])
            } catch {
                log("vvx-mcp: tool error: \(error)")
                return buildError(
                    id: id,
                    code: -32603,
                    message: error.localizedDescription
                )
            }

        default:
            log("vvx-mcp: unknown method: \(method)")
            return buildError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Response builders

    private func buildResponse(id: Any?, result: Any) -> [String: Any] {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id { response["id"] = id }
        return response
    }

    private func buildError(id: Any?, code: Int, message: String) -> [String: Any] {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { response["id"] = id }
        return response
    }

    // MARK: - Stdout writer (the ONLY place that writes to stdout)

    func writeResponse(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let line = String(data: data, encoding: .utf8)
        else {
            log("vvx-mcp: failed to serialize response")
            return
        }
        // Swift's print() adds \n — exactly what MCP stdio transport expects.
        Swift.print(line)
    }
}

// MARK: - Stderr logging (never touches stdout)

func log(_ message: String) {
    fputs("[vvx-mcp] \(message)\n", stderr)
}
