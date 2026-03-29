import Foundation

// MARK: - Parsed line type

/// The result of parsing a single line of yt-dlp stdout.
public enum ParsedStdoutLine: Sendable, Equatable {
    /// `[Merger] Merging formats into "/path/to/file.mp4"` — the final merged output path.
    case mergerOutputPath(String)
    /// `--print after_move:filepath` (or similar) — emits the final filepath as a raw absolute path line.
    /// Example: `/tmp/vvx-pathtest/Me at the zoo [jNQXAC9IVRw].mp4`
    case printedFilepath(String)
    /// `[ExtractAudio] Destination: /path/to/file.mp3`
    case extractAudioDestination(String)
    /// `[download] Destination: /path/to/file.mp4`
    case destinationPath(String)
    /// `[download]  52.3% of   123.4MiB at   3.21MiB/s ETA 00:28`
    case progress(percent: Double, speed: String, eta: String)
    /// `[youtube] <title>` or `[TikTok] <title>` — raw video title from extractor.
    case extractorTitle(String)
    /// `1920x1080` found anywhere in a line.
    case resolution(String)
    /// Line did not match any known pattern.
    case unknown
}

// MARK: - Parser

/// Pure, stateless yt-dlp stdout line parser.
/// All methods are static — no stored state, no dependencies.
/// Independently unit-testable without running yt-dlp.
public enum YtDlpOutputParser {

    /// Parses a single line of yt-dlp stdout and returns the semantic result.
    /// `currentFormat` is needed to suppress the `.mp3` ExtractAudio line for Reaction Kit
    /// (which keeps the `.mp4` as primary).
    public static func parse(_ line: String, currentFormat: DownloadFormat) -> ParsedStdoutLine {
        // Merger output path (highest priority — this is the final merged file)
        if let path = parseMergerOutputPath(line) {
            return .mergerOutputPath(path)
        }

        // Explicit printed final filepath (stable API): `--print after_move:filepath`
        if let path = parsePrintedFilepath(line) {
            return .printedFilepath(path)
        }

        // ExtractAudio destination — suppressed for Reaction Kit (we keep the .mp4)
        if currentFormat != .reactionKit {
            if let path = parseExtractAudioDestination(line) {
                return .extractAudioDestination(path)
            }
        }

        // Generic Destination: line (yt-dlp single-stream download)
        if let path = parseDestinationOutputPath(line) {
            // For Reaction Kit: only accept .mp4 destinations
            if currentFormat == .reactionKit {
                guard path.lowercased().hasSuffix(".mp4") else { return .unknown }
            }
            return .destinationPath(path)
        }

        // Download progress
        if let (pct, speed, eta) = parseProgress(line) {
            return .progress(percent: pct, speed: speed, eta: eta)
        }

        // Extractor title
        if let title = parseExtractorTitle(line) {
            return .extractorTitle(title)
        }

        // Resolution
        if let res = parseResolution(line) {
            return .resolution(res)
        }

        return .unknown
    }

    // MARK: - Internal parsers (public for unit testing)

    public static func parseMergerOutputPath(_ line: String) -> String? {
        if let m = line.firstMatch(of: #/\[Merger\]\s+Merging formats into\s+"([^"]+)"/#) {
            return String(m.1)
        }
        if let m = line.firstMatch(of: #/\[Merger\]\s+Merging formats into\s+'([^']+)'/#) {
            return String(m.1)
        }
        return nil
    }

    /// Parses an explicit filepath printed by yt-dlp via `--print after_move:filepath`.
    /// This is typically a single raw absolute path line, possibly quoted.
    public static func parsePrintedFilepath(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Common yt-dlp print styles:
        // - /abs/path/file.mp4
        // - "/abs/path/file.mp4"
        // - '/abs/path/file.mp4'
        var candidate = trimmed
        if (candidate.hasPrefix("\"") && candidate.hasSuffix("\""))
            || (candidate.hasPrefix("'") && candidate.hasSuffix("'")) {
            candidate = String(candidate.dropFirst().dropLast())
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        // Heuristic: must be an absolute POSIX path with a file extension.
        guard candidate.hasPrefix("/") else { return nil }
        guard candidate.contains("/") else { return nil }
        let ext = URL(fileURLWithPath: candidate).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }

        return candidate
    }

    public static func parseExtractAudioDestination(_ line: String) -> String? {
        let lower = line.lowercased()
        guard lower.contains("[extractaudio]") || lower.contains("[audio]") else { return nil }
        return parseDestinationOutputPath(line)
    }

    public static func parseDestinationOutputPath(_ line: String) -> String? {
        guard line.contains("Destination:") else { return nil }
        guard let m = line.firstMatch(of: #/Destination:\s*(.+)$/#) else { return nil }
        return String(m.1).trimmingCharacters(in: .whitespaces)
    }

    public static func parseProgress(_ line: String) -> (percent: Double, speed: String, eta: String)? {
        let pattern = #/\[download\]\s+(\d+(?:\.\d+)?)%\s*(?:of\s+[\d.]+\w+)?\s*(?:at\s+([\d.]+\s*(?:MiB|KiB)\/s))?\s*(?:ETA\s+([\d:]+))?/#
        guard let m = line.firstMatch(of: pattern) else { return nil }
        guard let pct = Double(m.1) else { return nil }
        let speed = m.2.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "-- MiB/s"
        let eta   = m.3.map { String($0) } ?? "--:--"
        return (pct / 100.0, speed, eta)
    }

    public static func parseExtractorTitle(_ line: String) -> String? {
        guard line.hasPrefix("["), !line.contains("Destination:") else { return nil }
        guard let m = line.firstMatch(of: #/^\[([^\]]+)\]\s+(.+)$/#) else { return nil }
        let prefix = String(m.1)
        let rest   = String(m.2).trimmingCharacters(in: .whitespaces)

        // Skip known non-title prefixes
        let skip: Set<String> = [
            "download", "merger", "fixup", "ffmpeg", "info", "verbose",
            "debug", "warning", "error", "dashsegments", "hlsnative",
        ]
        guard !skip.contains(prefix.lowercased()) else { return nil }

        // Skip progress-looking content
        guard !rest.contains("% of"), !rest.contains(" ETA ") else { return nil }
        guard !rest.hasPrefix("http://"), !rest.hasPrefix("https://") else { return nil }
        guard !rest.isEmpty else { return nil }

        return rest
    }

    public static func parseResolution(_ line: String) -> String? {
        guard let m = line.firstMatch(of: #/(\d{3,4}x\d{3,4})/#) else { return nil }
        return String(m.1)
    }
}
