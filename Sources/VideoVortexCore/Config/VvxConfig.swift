import Foundation

/// User-level configuration for the vvx CLI, stored at `~/.vvx/config.json`.
/// Written on first run with defaults; users can edit the file directly.
///
/// Intentionally separate from `~/Library/Application Support/VideoVortex/` which
/// belongs to the macOS app. CLI and app do not share config or storage roots.
public struct VvxConfig: Codable, Sendable {

    /// Where `vvx sense` stores extracted SRT transcripts.
    /// Default: `~/.vvx/transcripts`
    public var transcriptDirectory: String

    /// Where `vvx fetch` (non-archive) writes media files.
    /// Default: `~/.vvx/downloads`
    public var downloadDirectory: String

    /// Where `vvx fetch --archive` writes full project folders.
    /// Default: `~/.vvx/archive`
    public var archiveDirectory: String

    /// Legacy managed engine directory (`~/.vvx/engine/`). yt-dlp may still be resolved here if present; vvx does not install into it.
    /// Default: `~/.vvx/engine`
    public var engineDirectory: String

    /// Default behavior when `vvx <url>` is called with no flags.
    /// Always "sense" — never change this default.
    public var defaultFormat: String

    public init(
        transcriptDirectory: String = "~/.vvx/transcripts",
        downloadDirectory:   String = "~/.vvx/downloads",
        archiveDirectory:    String = "~/.vvx/archive",
        engineDirectory:     String = "~/.vvx/engine",
        defaultFormat:       String = "sense"
    ) {
        self.transcriptDirectory = transcriptDirectory
        self.downloadDirectory   = downloadDirectory
        self.archiveDirectory    = archiveDirectory
        self.engineDirectory     = engineDirectory
        self.defaultFormat       = defaultFormat
    }

    // MARK: - Resolved URLs (expand ~)

    public func resolvedTranscriptDirectory() -> URL {
        expand(transcriptDirectory)
    }

    public func resolvedDownloadDirectory() -> URL {
        expand(downloadDirectory)
    }

    public func resolvedArchiveDirectory() -> URL {
        expand(archiveDirectory)
    }

    public func resolvedEngineDirectory() -> URL {
        expand(engineDirectory)
    }

    private func expand(_ path: String) -> URL {
        URL(fileURLWithPath: path.replacingOccurrences(of: "~", with: NSHomeDirectory()))
    }
}

// MARK: - Persistence

extension VvxConfig {

    public static var configFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vvx/config.json")
    }

    /// Loads config from `~/.vvx/config.json`, writing defaults if the file doesn't exist.
    public static func load() -> VvxConfig {
        let url = configFileURL
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(VvxConfig.self, from: data) {
            return config
        }
        let defaults = VvxConfig()
        defaults.save()
        return defaults
    }

    /// Persists the current config to disk.
    public func save() {
        let url = Self.configFileURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url)
    }
}
