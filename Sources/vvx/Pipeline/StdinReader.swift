import Foundation

/// Reads a list of URLs from either stdin (pipe mode) or a batch file (--batch mode).
///
/// URL sources, in priority order:
///   1. Explicit `urls` array (direct CLI arguments)
///   2. Batch file path (`--batch path/to/urls.txt`)
///   3. stdin (if not a TTY — i.e. `cat urls.txt | vvx` or `echo "..." | vvx`)
///
/// Empty lines and lines starting with `#` are skipped.
/// Duplicate URLs are preserved (deduplication is the caller's responsibility).
public enum StdinReader {

    /// Returns the list of URLs to process, from the appropriate source.
    /// Never throws — missing files and empty stdin both return an empty array.
    public static func resolveURLs(
        explicit: [String],
        batchFile: String?
    ) -> [String] {
        if !explicit.isEmpty {
            return explicit.filter { !$0.isEmpty }
        }

        if let path = batchFile {
            return readLines(from: path)
        }

        if isatty(STDIN_FILENO) == 0 {
            return readLinesFromStdin()
        }

        return []
    }

    // MARK: - Private

    private static func readLines(from path: String) -> [String] {
        let expanded = (path as NSString).expandingTildeInPath
        guard let contents = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            fputs("vvx: warning: could not read batch file at \(path)\n", stderr)
            return []
        }
        return parse(contents)
    }

    private static func readLinesFromStdin() -> [String] {
        var lines: [String] = []
        while let line = readLine() {
            lines.append(line)
        }
        return parse(lines.joined(separator: "\n"))
    }

    private static func parse(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
