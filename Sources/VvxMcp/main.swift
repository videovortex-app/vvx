// vvx-mcp — Model Context Protocol server for VideoVortex
//
// Exposes `sense`, `fetch`, and `doctor` as native MCP tools to
// Claude Desktop, Cursor, Windsurf, and any MCP-compatible agent.
//
// Claude Desktop config:
//   {
//     "mcpServers": {
//       "videovortex": { "command": "vvx-mcp" }
//     }
//   }
//
// CRITICAL STDOUT RULE: stdout is exclusively for JSON-RPC 2.0 payloads.
// All logging goes to stderr. Never call print() directly — only
// McpServer.writeResponse() touches stdout.

import Foundation
import VideoVortexCore

// Start the MCP event loop in the Swift concurrency runtime.
// RunLoop.main.run() keeps the process alive until stdin closes.
VvxLogging.bootstrap()

Task {
    await McpServer.shared.run()
    exit(0)
}

RunLoop.main.run()
