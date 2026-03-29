import Foundation

/// User-selected download quality / container. Drives yt-dlp flags and post-processing.
public enum DownloadFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case bestVideo
    case video1080
    case video720
    case bRollMuted
    case audioOnlyMP3
    case reactionKit

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bestVideo:    return "Best Video"
        case .video1080:    return "1080p Video"
        case .video720:     return "720p Video"
        case .bRollMuted:   return "B-Roll (Muted Video)"
        case .audioOnlyMP3: return "Audio Only (MP3)"
        case .reactionKit:  return "Reaction Kit (Video + Audio + Subs)"
        }
    }

    public var fileExtension: String {
        self == .audioOnlyMP3 ? "mp3" : "mp4"
    }

    public var isVideo: Bool {
        self != .audioOnlyMP3
    }

    /// Formats that require a Pro license in the macOS app.
    /// The CLI has no license gating — all formats are always available.
    public var requiresProLicense: Bool {
        switch self {
        case .video720, .audioOnlyMP3:                      return false
        case .bestVideo, .video1080, .bRollMuted, .reactionKit: return true
        }
    }

    /// Formats available to restricted (Lite/expired) app users.
    public static func availableFormats(isRestricted: Bool) -> [DownloadFormat] {
        isRestricted ? [.video720, .audioOnlyMP3] : Array(DownloadFormat.allCases)
    }

    /// Clamps a stored selection to what Lite allows.
    public static func clampedForRestricted(_ format: DownloadFormat) -> DownloadFormat {
        format.requiresProLicense ? .video720 : format
    }

    // MARK: - yt-dlp flags

    /// Core `-f` / merge / remux flags only.
    public var ytDlpFlags: [String] {
        switch self {
        case .bestVideo:
            return [
                "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
                "--merge-output-format", "mp4",
            ]
        case .video1080:
            return [
                "-f", "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080][ext=mp4]",
                "--merge-output-format", "mp4",
            ]
        case .video720:
            return [
                "-f", "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/best[height<=720][ext=mp4]",
                "--merge-output-format", "mp4",
            ]
        case .bRollMuted:
            return [
                "-f", "bestvideo[ext=mp4]/bestvideo",
                "--remux-video", "mp4",
            ]
        case .audioOnlyMP3:
            return ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
        case .reactionKit:
            return [
                "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
                "--merge-output-format", "mp4",
                "-x", "--audio-format", "mp3", "--keep-video",
            ]
        }
    }

    /// Full yt-dlp argument list (after --ffmpeg-location). Composes flags with embeds and archive sidecars.
    /// - Parameter allSubtitleLanguages: When true, uses `en.*`; otherwise `en,en-orig` (fewer subtitle HTTP requests).
    public func ytDlpArguments(isArchiveMode: Bool, allSubtitleLanguages: Bool = false) -> [String] {
        switch self {
        case .reactionKit:
            return ytDlpFlags + videoEmbedAndArchiveSuffix(
                isArchiveMode: true,
                allSubtitleLanguages: allSubtitleLanguages
            )
        case .audioOnlyMP3:
            return audioOnlyArgs(isArchiveMode: isArchiveMode, allSubtitleLanguages: allSubtitleLanguages)
        case .bestVideo, .video1080, .video720, .bRollMuted:
            return ytDlpFlags + videoEmbedAndArchiveSuffix(
                isArchiveMode: isArchiveMode,
                allSubtitleLanguages: allSubtitleLanguages
            )
        }
    }

    private func videoEmbedAndArchiveSuffix(isArchiveMode: Bool, allSubtitleLanguages: Bool) -> [String] {
        let subLangs = allSubtitleLanguages
            ? YtDlpRateLimit.allSubsSubLangs
            : YtDlpRateLimit.defaultSubLangs
        var args: [String] = [
            "--embed-metadata",
            "--embed-chapters",
            "--embed-thumbnail",
        ]
        if isArchiveMode {
            args.append(contentsOf: [
                "--write-description",
                "--write-info-json",
                "--write-subs",
                "--write-auto-subs",
                "--sub-langs", subLangs,
                "--convert-subs", "srt",
                "--write-thumbnail",
                "--embed-subs",
            ])
        } else {
            args.append(contentsOf: [
                "--no-write-description",
                "--no-write-info-json",
            ])
        }
        return args
    }

    private func audioOnlyArgs(isArchiveMode: Bool, allSubtitleLanguages: Bool) -> [String] {
        let subLangs = allSubtitleLanguages
            ? YtDlpRateLimit.allSubsSubLangs
            : YtDlpRateLimit.defaultSubLangs
        var args = ytDlpFlags + ["--embed-metadata"]
        if isArchiveMode {
            args.append(contentsOf: [
                "--write-description",
                "--write-info-json",
                "--write-subs",
                "--write-auto-subs",
                "--sub-langs", subLangs,
                "--convert-subs", "srt",
                "--write-thumbnail",
            ])
        } else {
            args.append(contentsOf: [
                "--no-write-description",
                "--no-write-info-json",
            ])
        }
        return args
    }
}
