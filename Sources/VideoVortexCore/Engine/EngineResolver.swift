import Foundation

/// Resolves paths to yt-dlp and ffmpeg for a given environment.
///
/// Priority order for yt-dlp:
///   1. Managed path (e.g. ~/.vvx/engine/yt-dlp or ~/Library/AS/VideoVortex/Engine/yt-dlp)
///   2. System PATH (walked from ProcessInfo.processInfo.environment["PATH"])
///   3. Returns nil
///
/// Priority order for ffmpeg:
///   1. Provided bundle path (macOS app bundles ffmpeg as a resource)
///   2. Managed path (e.g. ~/.vvx/engine/ffmpeg)
///   3. System PATH
///   4. Returns nil
public struct EngineResolver: Sendable {

    /// Directory where the managed yt-dlp (and optionally ffmpeg) binary lives.
    public let managedEngineDirectory: URL

    /// Optional path to a bundled ffmpeg (used by the macOS app).
    public let bundledFfmpegURL: URL?

    public init(managedEngineDirectory: URL, bundledFfmpegURL: URL? = nil) {
        self.managedEngineDirectory = managedEngineDirectory
        self.bundledFfmpegURL = bundledFfmpegURL
    }

    // MARK: - Resolution

    /// Resolved path to yt-dlp, or nil if not found anywhere.
    public func resolvedYtDlpURL() -> URL? {
        let managed = managedEngineDirectory.appendingPathComponent("yt-dlp")
        if FileManager.default.fileExists(atPath: managed.path) {
            return managed
        }
        return pathLookup("yt-dlp")
    }

    /// Resolved path to ffmpeg, or nil if not found anywhere.
    public func resolvedFfmpegURL() -> URL? {
        if let bundled = bundledFfmpegURL,
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let managed = managedEngineDirectory.appendingPathComponent("ffmpeg")
        if FileManager.default.fileExists(atPath: managed.path) {
            return managed
        }
        return pathLookup("ffmpeg")
    }

    // MARK: - PATH search

    /// Searches for a binary by walking the process PATH environment variable.
    /// On macOS, prepends common Homebrew directories as a fast path before walking PATH.
    /// Falls back to `/usr/bin/which` if PATH walk produces no result.
    public func pathLookup(_ binary: String) -> URL? {
        var searchDirs: [String] = []

#if os(macOS)
        // Fast path for Homebrew installs (avoids full PATH walk in the common case).
        searchDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
#endif

        // Walk the process PATH on all platforms.
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        searchDirs += pathEnv.split(separator: ":").map(String.init)

        for dir in searchDirs {
            let candidate = URL(fileURLWithPath: "\(dir)/\(binary)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Last resort: shell `which`.
        return whichLookup(binary)
    }

    private func whichLookup(_ binary: String) -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [binary]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = output, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}

// MARK: - Preset Resolvers

extension EngineResolver {

    /// Resolver for the vvx CLI and vvx-serve server.
    /// Managed directory: ~/.vvx/engine/
    public static var cliResolver: EngineResolver {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return EngineResolver(
            managedEngineDirectory: home.appendingPathComponent(".vvx/engine", isDirectory: true)
        )
    }

    /// Resolver for the macOS app.
    /// Managed directory: ~/Library/Application Support/VideoVortex/Engine/
    /// Bundled ffmpeg should be passed from Bundle.main.
    public static func appResolver(bundledFfmpegURL: URL?) -> EngineResolver {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return EngineResolver(
            managedEngineDirectory: base.appendingPathComponent("VideoVortex/Engine", isDirectory: true),
            bundledFfmpegURL: bundledFfmpegURL
        )
    }
}
