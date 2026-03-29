import Foundation

// MARK: - SRTBlock

/// A single subtitle block parsed from an `.srt` file.
///
/// Blocks represent natural SRT granularity (~3–5 seconds, ~10–30 words each).
/// This is the fundamental indexing and search result unit for FTS5 and the
/// context window returned by `vvx search`.
public struct SRTBlock: Sendable, Codable, Equatable {

    /// Sequential block number from the source SRT file (1-based, as written).
    public let index: Int

    /// Start timestamp in SRT format, e.g. `"00:14:32,000"`.
    public let startTime: String

    /// End timestamp in SRT format, e.g. `"00:14:47,000"`.
    public let endTime: String

    /// Start time in decimal seconds (e.g. `872.0`).
    /// Used for ordering, context window expansion, and ffmpeg clip commands.
    public let startSeconds: Double

    /// End time in decimal seconds.
    public let endSeconds: Double

    /// Plain text content of this block.
    /// HTML entities are decoded; word-level timing tags are stripped.
    /// Multi-line subtitle text is joined with a space.
    public let text: String

    public init(
        index: Int,
        startTime: String,
        endTime: String,
        startSeconds: Double,
        endSeconds: Double,
        text: String
    ) {
        self.index        = index
        self.startTime    = startTime
        self.endTime      = endTime
        self.startSeconds = startSeconds
        self.endSeconds   = endSeconds
        self.text         = text
    }
}

// MARK: - SRTParser

/// Parses `.srt` subtitle files into structured `SRTBlock` arrays.
///
/// Pure function — no file I/O, no side effects.  Feed it a raw SRT string,
/// get back an ordered array of blocks.  All normalisation (CRLF endings,
/// HTML entities, yt-dlp word-timing tags) is handled here so callers
/// always receive clean, indexable text.
public enum SRTParser {

    // MARK: - Public API

    /// Parse a raw SRT string into an ordered array of `SRTBlock` values.
    ///
    /// - Parameter srtContent: The raw `.srt` file content (any line endings).
    /// - Returns: Blocks in source order.
    ///   - Empty blocks (no text after cleanup) are dropped silently.
    ///   - Duplicate block indices (a rare yt-dlp artefact) are kept as-is.
    public static func parse(_ srtContent: String) -> [SRTBlock] {
        // Normalise CRLF and bare CR so group-splitting works uniformly.
        let normalised = srtContent
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r",   with: "\n")

        // SRT blocks are separated by one or more blank lines.
        // Split on any run of two or more newlines to handle extra spacing.
        let groups = normalised.components(separatedBy: "\n\n")

        var blocks: [SRTBlock] = []

        for group in groups {
            let lines = group
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            // A valid block needs at least an index line and a timestamp line.
            guard lines.count >= 2 else { continue }

            // Line 0: pure integer index.
            guard let index = Int(lines[0]) else { continue }

            // Line 1: "HH:MM:SS,mmm --> HH:MM:SS,mmm"
            let timestampLine = lines[1]
            guard timestampLine.contains("-->") else { continue }

            let parts = timestampLine.components(separatedBy: "-->")
            guard parts.count == 2 else { continue }

            let startRaw = parts[0].trimmingCharacters(in: .whitespaces)
            let endRaw   = parts[1].trimmingCharacters(in: .whitespaces)

            guard let startSec = parseTimestamp(startRaw),
                  let endSec   = parseTimestamp(endRaw) else { continue }

            // Everything from line 2 onward is subtitle text.
            // Multi-line blocks are joined with a space.
            let rawText     = lines.dropFirst(2).joined(separator: " ")
            let cleanedText = cleanText(rawText)

            // Drop blocks with no usable text after cleanup.
            guard !cleanedText.isEmpty else { continue }

            blocks.append(SRTBlock(
                index:        index,
                startTime:    startRaw,
                endTime:      endRaw,
                startSeconds: startSec,
                endSeconds:   endSec,
                text:         cleanedText
            ))
        }

        return blocks
    }

    /// Concatenate all block text into a single plain-text string separated by spaces.
    ///
    /// Suitable for `--transcript` plain-text output and rough token estimation.
    public static func toPlainText(_ blocks: [SRTBlock]) -> String {
        blocks.map(\.text).joined(separator: " ")
    }

    // MARK: - Timestamp parsing

    /// Convert `"HH:MM:SS,mmm"` or `"HH:MM:SS.mmm"` to decimal seconds.
    ///
    /// Accepts both comma (SRT standard) and dot (yt-dlp auto-generated) as
    /// the millisecond separator.  Returns `nil` for any malformed input.
    static func parseTimestamp(_ raw: String) -> Double? {
        let normalised = raw.replacingOccurrences(of: ",", with: ".")
        let parts      = normalised.components(separatedBy: ":")

        guard parts.count == 3,
              let hours   = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }

        return hours * 3_600 + minutes * 60 + seconds
    }

    // MARK: - Text cleanup

    /// Strip yt-dlp word-timing tags and decode HTML entities from subtitle text.
    ///
    /// Handles two tag formats produced by yt-dlp auto-caption generation:
    ///   `<00:14:32.040>` — absolute timestamp marker per word
    ///   `<c.colorName>text</c>` — colour / positioning tags
    static func cleanText(_ raw: String) -> String {
        var text = raw

        // Strip absolute timestamp tags: <HH:MM:SS.mmm>
        text = removePattern(#"<\d{2}:\d{2}:\d{2}\.\d+>"#, from: text)

        // Strip all remaining XML/HTML tags: <c>, </c>, <i>, <b>, <c.white>, etc.
        text = removePattern(#"<[^>]+>"#, from: text)

        // Decode the HTML entities yt-dlp commonly produces.
        text = text
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // Collapse any runs of multiple spaces left by tag removal.
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func removePattern(_ pattern: String, from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
