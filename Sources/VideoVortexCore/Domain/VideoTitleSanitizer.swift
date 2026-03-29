import Foundation

/// Cleans yt-dlp extractor titles for use as filenames and Spotlight comments.
public enum VideoTitleSanitizer {

    /// Strips emoji, junk punctuation, collapses whitespace, and truncates at a word boundary.
    public static func clean(_ originalTitle: String, maxLength: Int = 65) -> String {
        var clean = originalTitle

        clean = String(clean.unicodeScalars.filter { !$0.properties.isEmoji })

        let junkRegex = try! Regex("[#\\|\\*\\\"\\\\/\\:\\?\\<\\>👇🔥🚨]")
        clean = clean.replacing(junkRegex, with: "")

        clean = clean.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)

        if clean.count > maxLength {
            let index = clean.index(clean.startIndex, offsetBy: maxLength)
            let truncated = String(clean[..<index])
            if let lastSpace = truncated.lastIndex(of: " ") {
                return String(truncated[..<lastSpace]) + "..."
            }
            return truncated + "..."
        }
        return clean
    }

    /// Writes the original title to Finder's Spotlight comment via extended attributes.
    /// macOS-only — no-op on Linux where xattr/Finder metadata has no meaning.
    public static func writeFinderCommentViaXattr(to fileURL: URL, comment: String) {
#if os(macOS)
        let xattrURL = URL(fileURLWithPath: "/usr/bin/xattr")
        guard FileManager.default.fileExists(atPath: xattrURL.path) else { return }

        let proc = Process()
        proc.executableURL = xattrURL
        proc.arguments = ["-w", "com.apple.metadata:kMDItemFinderComment", comment, fileURL.path]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
#endif
    }
}
