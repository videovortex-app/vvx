import Foundation

/// Parses human-friendly time strings into decimal seconds.
///
/// Accepts every format a human or agent is likely to type:
///   - Colon notation: `"1:30"`, `"01:14:32"`, `"1:30:00.500"`
///   - Raw seconds:    `"90"`, `"90.5"`
///   - Shorthand:      `"1m30s"`, `"2h1m30s"`, `"45s"`, `"1h"`, `"1h30s"`
///
/// Returns `nil` for unparseable input — callers decide how to surface the error.
public enum TimeParser {

    public static func parseToSeconds(_ input: String) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let result = parseShorthand(trimmed) { return result }
        if let result = parseColonNotation(trimmed) { return result }
        if let result = Double(trimmed), result >= 0 { return result }

        return nil
    }

    /// Format seconds back to `HH:MM:SS` for JSON output and smart file naming.
    public static func formatHHMMSS(_ totalSeconds: Double) -> String {
        let total = Int(totalSeconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Compact format for file names: `01h14m32s` or `14m32s` or `32s`.
    public static func formatCompact(_ totalSeconds: Double) -> String {
        let total = Int(totalSeconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%02dh%02dm%02ds", h, m, s) }
        if m > 0 { return String(format: "%02dm%02ds", m, s) }
        return String(format: "%02ds", s)
    }

    // MARK: - Private

    /// Matches `1h30m45s`, `2m30s`, `45s`, `1h`, `1h30s`, etc.
    private static func parseShorthand(_ input: String) -> Double? {
        let pattern = #"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(input.startIndex..., in: input)
        guard let match = regex.firstMatch(in: input, range: range) else { return nil }

        var seconds: Double = 0
        var hadComponent = false

        if let hRange = Range(match.range(at: 1), in: input), let h = Double(input[hRange]) {
            seconds += h * 3600
            hadComponent = true
        }
        if let mRange = Range(match.range(at: 2), in: input), let m = Double(input[mRange]) {
            seconds += m * 60
            hadComponent = true
        }
        if let sRange = Range(match.range(at: 3), in: input), let s = Double(input[sRange]) {
            seconds += s
            hadComponent = true
        }

        return hadComponent ? seconds : nil
    }

    /// Matches `H:MM:SS`, `HH:MM:SS`, `MM:SS`, `H:MM:SS.mmm`, etc.
    private static func parseColonNotation(_ input: String) -> Double? {
        let parts = input.components(separatedBy: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }

        if parts.count == 2 {
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            guard m >= 0, s >= 0 else { return nil }
            return m * 60 + s
        }

        guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
            return nil
        }
        guard h >= 0, m >= 0, s >= 0 else { return nil }
        return h * 3600 + m * 60 + s
    }
}
