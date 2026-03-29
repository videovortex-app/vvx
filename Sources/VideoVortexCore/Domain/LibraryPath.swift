import Foundation

/// Maps yt-dlp `extractor_key` folder names to display platform strings.
public enum LibraryPath {

    private static let extractorDisplayNames: [String: String] = [
        "youtube":    "YouTube",
        "youtubetab": "YouTube",
        "twitter":    "Twitter",
        "x.com":      "X",
        "instagram":  "Instagram",
        "tiktok":     "TikTok",
        "vimeo":      "Vimeo",
        "twitch":     "Twitch",
        "reddit":     "Reddit",
        "facebook":   "Facebook",
        "rumble":     "Rumble",
        "bilibili":   "Bilibili",
        "niconico":   "Niconico",
        "soundcloud": "SoundCloud",
        "bandcamp":   "Bandcamp",
    ]

    /// Derives a platform display name from a file's path relative to a library root.
    /// The first path segment under `libraryRoot` is treated as the yt-dlp extractor key.
    public static func platformDisplayName(libraryRoot: URL, fileURL: URL) -> String? {
        let root = libraryRoot.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(root) else { return nil }
        let rel = String(path.dropFirst(root.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let first = rel.split(separator: "/").first, !first.isEmpty else { return nil }
        return displayName(forExtractorFolder: String(first))
    }

    /// Human-readable platform from a single folder segment (yt-dlp extractor key).
    public static func displayName(forExtractorFolder folder: String) -> String {
        let key = folder.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let mapped = extractorDisplayNames[key] { return mapped }
        if folder.isEmpty { return folder }
        return folder.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
