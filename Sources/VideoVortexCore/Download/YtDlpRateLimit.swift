import Foundation

// MARK: - YouTube / platform throttling (HTTP 429)

/// Shared policy for subtitle language scope, rate-limit detection, and backoff.
public enum YtDlpRateLimit: Sendable {

    /// Default `--sub-langs`: avoids `en.*` regex matching `en-de`, `en-de-DE`, etc.,
    /// which triggers many extra subtitle HTTP requests and aggravates 429s.
    public static let defaultSubLangs = "en,en-orig"

    /// Opt-in `--all-subs`: broader English pattern (higher request volume).
    public static let allSubsSubLangs = "en.*"

    /// Seconds to wait before each 429 retry attempt (after the failure that triggered backoff).
    public static let backoffSecondsBeforeRetry: [TimeInterval] = [15, 45, 90]

    public static func isProbablyRateLimited(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("rate limit")
            || lower.contains("too many requests")
            || lower.contains("http error 429")
            || lower.contains(": 429")
            || lower.contains(" 429 ")
            || lower.contains(" 429\n")
    }

    /// Human-facing notice on **stderr** only (never stdout JSON).
    public static func printBackoffNotice(attemptIndex: Int) {
        let total = backoffSecondsBeforeRetry.count
        let msg =
            "⚠️ Rate-limited by the platform (HTTP 429). Backing off and retrying "
            + "(\(attemptIndex + 1)/\(total))…\n"
        fputs(msg, stderr)
    }
}
