import Foundation
import Hummingbird
import VideoVortexCore

// MARK: - POST /export

struct ExportRequest: Decodable {
    /// Array of absolute outputPath strings (from /library or /status responses).
    let paths: [String]
    /// Optional target format hint for future CapCut/Obsidian project generation.
    let format: String?
}

struct ExportResponse: Encodable {
    let zipPath: String
    let sizeBytes: Int64
    let message: String
}

/// Zips the requested archive folders (or files) and returns the path to the .zip.
/// The zip is written to ~/.vvx/exports/ and the path is returned in the JSON response.
func handleExport(
    request: Request,
    context: some RequestContext
) async throws -> Response {
    guard let body = try? await request.body.collect(upTo: 1024 * 4),
          let decoded = try? JSONDecoder().decode(ExportRequest.self, from: Data(body.readableBytesView))
    else {
        return jsonError(status: .badRequest, message: "Invalid JSON body. Expected: {\"paths\": [...]}")
    }

    guard !decoded.paths.isEmpty else {
        return jsonError(status: .badRequest, message: "paths array must not be empty.")
    }

    let exportsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".vvx/exports", isDirectory: true)
    try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

    let zipName = "vvx-export-\(Int(Date().timeIntervalSince1970)).zip"
    let zipURL  = exportsDir.appendingPathComponent(zipName)

    // Build the list of source URLs to zip.
    // For archive items, zip the containing folder; for quick items, zip the file itself.
    var sources: [URL] = []
    for path in decoded.paths {
        let url = URL(fileURLWithPath: path)
        let isArchive = path.contains(MediaStoragePaths.archiveFolderName)
        let source    = isArchive ? url.deletingLastPathComponent() : url
        if FileManager.default.fileExists(atPath: source.path) {
            sources.append(source)
        }
    }

    guard !sources.isEmpty else {
        return jsonError(status: .notFound, message: "No valid files found at the provided paths.")
    }

    guard let zipBinaryURL = EngineResolver.cliResolver.pathLookup("zip") else {
        return jsonError(status: .internalServerError, message: "zip not found on PATH. Install zip: brew install zip (macOS) or apt-get install zip (Linux).")
    }
    let process = Process()
    process.executableURL = zipBinaryURL
    process.arguments = ["-r", zipURL.path] + sources.map(\.path)
    let errPipe = Pipe()
    process.standardError = errPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return jsonError(status: .internalServerError, message: "zip failed: \(error.localizedDescription)")
    }

    guard process.terminationStatus == 0,
          FileManager.default.fileExists(atPath: zipURL.path)
    else {
        let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return jsonError(status: .internalServerError, message: "zip exited with error: \(errMsg)")
    }

    let sizeAttr = try? FileManager.default.attributesOfItem(atPath: zipURL.path)
    let size     = sizeAttr?[.size] as? Int64 ?? 0

    let response = ExportResponse(
        zipPath: zipURL.path,
        sizeBytes: size,
        message: "Export ready at \(MediaStoragePaths.tildePath(for: zipURL))"
    )
    return try jsonResponse(response)
}
