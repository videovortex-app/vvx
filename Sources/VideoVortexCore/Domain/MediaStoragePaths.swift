import Foundation

/// Canonical storage roots and UserDefaults keys shared across app, CLI, and server.
public enum MediaStoragePaths {

    public static let quickFolderName   = "VideoVortex"
    public static let archiveFolderName = "VideoVortex Archives"

    public static let isArchiveModeUserDefaultsKey = "isArchiveModeEnabled"

    /// ~/Downloads/VideoVortex/ — quick (non-archive) downloads root.
    public static func quickDownloadsRoot() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent(quickFolderName, isDirectory: true)
    }

    /// ~/Movies/VideoVortex Archives/ — archive mode root.
    public static func archiveRoot() -> URL? {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(archiveFolderName, isDirectory: true)
    }

    /// Replaces the home directory prefix with ~ for display in Settings / CLI output.
    public static func tildePath(for url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
