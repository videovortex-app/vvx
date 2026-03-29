import Foundation

/// Streaming events emitted by `VideoDownloader` as an `AsyncStream<DownloadProgress>`.
///
/// Consumers:
/// - CLI:            iterates with `for await event in stream`, prints to stderr, prints JSON to stdout on completion
/// - Local Agent API: consumed in a Task per active download; progress stored for `/status/{taskId}` polling
/// - macOS app:      `@Observable` adapter subscribes in a `Task` and updates `DownloadTask` properties for SwiftUI
public enum DownloadProgress: Sendable {

    /// yt-dlp process launched, waiting for first output.
    case preparing

    /// Download percentage, network speed, and estimated time remaining.
    case downloading(percent: Double, speed: String, eta: String)

    /// yt-dlp emitted a title line — display name is available.
    case titleResolved(String)

    /// Video resolution parsed from yt-dlp output.
    case resolutionResolved(String)

    /// yt-dlp reported the output file path (Destination: or Merger: line).
    case outputPathResolved(String)

    /// Retry: yt-dlp exited non-zero; engine was refreshed; download restarting.
    case retrying

    /// Download and post-processing succeeded. Contains the full structured result.
    case completed(VideoMetadata)

    /// Download failed with a typed error (stderr classification, rate limits, etc.).
    case failed(VvxError)
}

// MARK: - Convenience

extension DownloadProgress {
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }

    public var videoMetadata: VideoMetadata? {
        if case .completed(let m) = self { return m }
        return nil
    }
}
