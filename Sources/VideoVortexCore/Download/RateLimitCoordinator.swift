import Foundation

// MARK: - RateLimitCoordinator

/// Shared, actor-isolated 429 gate for sync's concurrent TaskGroup workers.
///
/// **Why this exists:** Per-process backoff inside `VideoSenser` / `VideoDownloader` is
/// not sufficient when three workers run concurrently.  If worker 1 sleeps for 15 s but
/// workers 2 and 3 keep firing, the platform may shadowban the entire IP.
///
/// **Usage inside a TaskGroup child:**
/// ```swift
/// let coordinator = RateLimitCoordinator()
/// // In each child:
/// await coordinator.waitUntilSafeToProceed()
/// // … run yt-dlp …
/// // On .rateLimited error:
/// await coordinator.registerRateLimit()
/// ```
///
/// The delay tiers (15 s → 45 s → 90 s) are sourced from `YtDlpRateLimit` so policy
/// stays in one place across all vvx operations.
public actor RateLimitCoordinator {

    // MARK: - State

    private var pauseUntil:   Date? = nil
    private var backoffIndex: Int   = 0

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Suspends the caller until the global rate-limit window has cleared.
    ///
    /// If there is no active pause, returns immediately.  Safe to call from any
    /// actor-isolated context — the compiler enforces the `await`.
    public func waitUntilSafeToProceed() async {
        guard var until = pauseUntil else { return }
        // Loop handles the edge case where a new `registerRateLimit` arrives
        // while this task is sleeping (the window may have advanced).
        while until > .now {
            let nanos = UInt64(max(0, until.timeIntervalSinceNow) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            // Re-read in case another worker advanced the window while we slept.
            guard let refreshed = pauseUntil else { return }
            until = refreshed
        }
    }

    /// Registers a rate-limit event and advances the global pause window.
    ///
    /// Uses the next tier delay from `YtDlpRateLimit.backoffSecondsBeforeRetry`
    /// (15 s → 45 s → 90 s, then stays at 90 s).
    ///
    /// `pauseUntil` is set to `max(current, now + delay)` so workers that have
    /// already advanced the window are never rolled back.
    public func registerRateLimit() {
        let tiers = YtDlpRateLimit.backoffSecondsBeforeRetry
        let delay = tiers[min(backoffIndex, tiers.count - 1)]
        backoffIndex = min(backoffIndex + 1, tiers.count - 1)

        let proposed = Date.now.addingTimeInterval(delay)
        pauseUntil   = max(pauseUntil ?? .distantPast, proposed)

        Foundation.fputs(
            "⚠️  Rate-limited (HTTP 429). All sync workers pausing \(Int(delay))s…\n",
            stderr
        )
    }

    /// Resets backoff state after a run completes (or for testing).
    public func reset() {
        pauseUntil   = nil
        backoffIndex = 0
    }
}
