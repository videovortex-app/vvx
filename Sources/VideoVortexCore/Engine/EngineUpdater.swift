import Foundation

/// Stub — auto-update removed.
///
/// vvx no longer downloads or installs yt-dlp. yt-dlp must be installed
/// by the user via their system package manager (Homebrew, pip, etc.).
/// This type is retained as a shell so callers compile without changes.
public actor EngineUpdater {

    public static let shared = EngineUpdater()

    /// Key retained for `vvx engine status` to display a previously stored version string.
    public static let versionDefaultsKey = "vvx_engine_version"

    // MARK: - No-op auto-update (was: self-healing retry)

    /// Always returns false. Auto-update removed; yt-dlp is managed by the user's
    /// system package manager.
    public func updateIfNewerAvailable(engineDirectory: URL) async -> Bool {
        false
    }

    // MARK: - Install guide (was: force install from GitHub)

    /// Throws with installation instructions. vvx no longer installs yt-dlp.
    public func forceInstallLatest(engineDirectory: URL) async throws -> String {
        throw EngineUpdateError.usePackageManager
    }

    public enum EngineUpdateError: Error, LocalizedError, Equatable {
        case usePackageManager

        public var errorDescription: String? {
            """
            vvx no longer manages yt-dlp installation.

            Install yt-dlp using your system package manager:

              macOS (Homebrew):  brew install yt-dlp
              All platforms:     pip install yt-dlp
              Direct binary:     https://github.com/yt-dlp/yt-dlp#installation

            After installing, re-run your command. Run 'vvx doctor' to verify.
            """
        }
    }
}
