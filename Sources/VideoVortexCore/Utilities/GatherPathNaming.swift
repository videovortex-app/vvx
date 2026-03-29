import Foundation

/// Deterministic path / filename pieces for `vvx gather` (Phase 3.5 Step 2).
/// Kept in core so unit tests do not depend on the `vvx` executable target.
public enum GatherPathNaming {

    /// Folder token: `VideoTitleSanitizer.clean` + max 40 + spaces → `_`; empty → `gather`.
    public static func sanitizeFolderQuery(_ query: String) -> String {
        let cleaned = VideoTitleSanitizer.clean(query, maxLength: 40)
            .replacingOccurrences(of: " ", with: "_")
        return cleaned.isEmpty ? "gather" : cleaned
    }

    /// Uploader token for filenames: strict shell-safe form of the uploader name.
    /// Spaces → `_`, then any character that is not `[a-zA-Z0-9_-]` is stripped.
    /// Falls back to `"Unknown"` when uploader is nil or empty after cleaning.
    public static func uploaderToken(_ uploader: String?) -> String {
        guard let raw = uploader, !raw.isEmpty else { return "Unknown" }
        let spaced = raw.replacingOccurrences(of: " ", with: "_")
        let safe   = shellSafeComponent(spaced, maxLength: 30)
        return safe.isEmpty ? "Unknown" : safe
    }

    /// Filename snippet: first 5 whitespace-separated tokens, joined with `_`, shell-safe, max 40.
    public static func filenameSnippet(from text: String) -> String {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).prefix(5)
        let joined = tokens.joined(separator: "_")
        let safe   = shellSafeComponent(joined, maxLength: 40)
        return safe.isEmpty ? "snippet" : safe
    }

    /// Strips all characters that are not alphanumeric, underscore, or dash.
    /// Applies after general `VideoTitleSanitizer` cleaning so the result is safe
    /// for shell scripts, `bash -c`, and editor tool integrations.
    public static func shellSafeComponent(_ raw: String, maxLength: Int) -> String {
        // First broad-clean with VideoTitleSanitizer (strips emoji, junk punctuation, etc.)
        let broadCleaned = VideoTitleSanitizer.clean(raw, maxLength: maxLength)
        // Then enforce strict shell-safe whitelist: only [a-zA-Z0-9_-]
        let strict = broadCleaned.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if c.isLetter || c.isNumber { return c }
            if c == "_" || c == "-"     { return c }
            return "_"
        }
        // Collapse consecutive underscores and trim leading/trailing underscores
        var result = String(strict)
        while result.contains("__") {
            result = result.replacingOccurrences(of: "__", with: "_")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(result.prefix(maxLength))
    }

    /// Parses SRT-style end timestamps (`HH:MM:SS,mmm`) for clip bounds.
    public static func parseSRTTimestampToSeconds(_ endTime: String) -> Double? {
        TimeParser.parseToSeconds(endTime.replacingOccurrences(of: ",", with: "."))
    }

    /// Zero-padded 1-based index for gather filenames; width = max(2, digit count of `total`).
    public static func paddedClipIndex(_ index: Int, total: Int) -> String {
        let padWidth = max(2, String(total).count)
        let s = String(index)
        return String(repeating: "0", count: max(0, padWidth - s.count)) + s
    }
}
