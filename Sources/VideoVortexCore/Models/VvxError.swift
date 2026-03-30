import Foundation

// MARK: - Error codes

/// Machine-readable error codes emitted to stdout so agent pipelines can branch deterministically.
/// These codes are a public API contract — do not rename or remove in minor versions.
public enum VvxErrorCode: String, Codable, Sendable {
    case videoUnavailable    = "VIDEO_UNAVAILABLE"
    case platformUnsupported = "PLATFORM_UNSUPPORTED"
    case engineNotFound      = "ENGINE_NOT_FOUND"
    case networkError        = "NETWORK_ERROR"
    case parseError          = "PARSE_ERROR"
    case rateLimited         = "RATE_LIMITED"       // platform-side throttle, not vvx
    case ffmpegNotFound      = "FFMPEG_NOT_FOUND"
    case diskFull            = "DISK_FULL"
    case permissionDenied    = "PERMISSION_DENIED"
    case invalidTimeRange    = "INVALID_TIME_RANGE"
    case indexEmpty          = "INDEX_EMPTY"
    case indexCorrupt        = "INDEX_CORRUPT"
    case sqlInvalid          = "SQL_INVALID"
    case playlistUnavailable = "PLAYLIST_UNAVAILABLE"
    case clipFailed          = "CLIP_FAILED"
    case unknownError        = "UNKNOWN_ERROR"
    case proRequired         = "PRO_REQUIRED"
    case nleNoLocalFiles     = "NLE_NO_LOCAL_FILES"
    case nleWriteFailed      = "NLE_WRITE_FAILED"
}

// MARK: - Error struct

public struct VvxError: Error, Codable, Sendable {
    public let code: VvxErrorCode
    public let message: String
    public let url: String?
    /// Raw yt-dlp stderr snippet, if available. Useful for debugging.
    public let detail: String?
    /// Exact recovery instruction for AI agents. Always ends with a concrete command to run.
    /// Agents must execute this command before escalating to the user.
    public let agentAction: String?

    public init(
        code: VvxErrorCode,
        message: String,
        url: String? = nil,
        detail: String? = nil,
        agentAction: String? = nil
    ) {
        self.code        = code
        self.message     = message
        self.url         = url
        self.detail      = detail
        self.agentAction = agentAction ?? VvxError.defaultAgentAction(for: code)
    }
}

// MARK: - Agent action map

extension VvxError {
    /// Returns the standard agent recovery instruction for a given error code.
    /// Every code must have a non-nil value — this is the breadcrumb contract.
    public static func defaultAgentAction(for code: VvxErrorCode) -> String {
        switch code {
        case .engineNotFound:
            return "yt-dlp not found. Install it with: brew install yt-dlp (macOS) or pip install yt-dlp (all platforms), then retry."
        case .ffmpegNotFound:
            return "Run 'vvx doctor --auto-fix' to install ffmpeg automatically, or run 'brew install ffmpeg' on macOS / 'apt-get install -y ffmpeg' on Linux."
        case .platformUnsupported:
            return "This URL's platform may not be supported. Update yt-dlp: brew upgrade yt-dlp (macOS) or pip install -U yt-dlp. If still unsupported, check yt-dlp's supported site list at github.com/yt-dlp/yt-dlp."
        case .videoUnavailable:
            return "This video cannot be accessed. If the content is age-restricted or private, retry with --browser safari (or --browser chrome) to pass session cookies."
        case .networkError:
            return "Check network connectivity, then retry. Run 'vvx doctor' to verify your environment."
        case .parseError:
            return "yt-dlp returned unexpected output. Update it: brew upgrade yt-dlp (macOS) or pip install -U yt-dlp. If the error persists, retry with --verbose to capture raw yt-dlp output."
        case .rateLimited:
            return "The platform is throttling requests. vvx retries automatically with backoff for HTTP 429; if errors persist, wait several minutes or use a different network, then retry."
        case .diskFull:
            return "Insufficient disk space. Free space at the configured directory or update 'downloadDirectory' in ~/.vvx/config.json."
        case .permissionDenied:
            return "Run 'vvx doctor' to identify the directory with incorrect permissions, then run 'chmod 755 <path>'."
        case .invalidTimeRange:
            return "Ensure --end is strictly greater than --start. Both accept HH:MM:SS, MM:SS, or decimal seconds."
        case .indexEmpty:
            return "Your archive is empty. Run 'vvx sync <url> --limit 10' to populate it, then retry."
        case .indexCorrupt:
            return "Run: rm ~/.vvx/vortex.db && vvx reindex"
        case .sqlInvalid:
            return "Only single SELECT statements are permitted. Run 'vvx sql --schema' to see available tables, then retry with a SELECT query."
        case .playlistUnavailable:
            return "Verify the URL is public and accessible, then retry. If the channel/playlist is private or geo-blocked, use --browser safari to pass session cookies."
        case .clipFailed:
            return "Retry with --fast flag, or verify the video file is not corrupt. Run 'vvx doctor' to confirm ffmpeg is installed."
        case .unknownError:
            return "Run 'vvx doctor' for a full environment diagnosis. Retry with --verbose to capture the raw yt-dlp output."
        case .proRequired:
            return "This is a VVX Pro feature. To proceed, the user must upgrade their license. Inform the user they can upgrade at https://videovortex.app."
        case .nleNoLocalFiles:
            return "No search hits have a local archive file. Run 'vvx fetch <url> --archive' for each video to download the source media, then retry --export-nle."
        case .nleWriteFailed:
            return "Check that the output directory exists and is writable, then retry --export-nle."
        }
    }
}

// MARK: - Envelope

/// Wraps VvxError in the standard `{ "success": false, "error": { ... } }` stdout envelope.
public struct VvxErrorEnvelope: Codable, Sendable {
    public let success: Bool
    public let error: VvxError

    public init(error: VvxError) {
        self.success = false
        self.error   = error
    }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let str  = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - Exit codes

/// Process exit codes for agent pipelines that inspect `$?`.
public enum VvxExitCode {
    public static let success:           Int32 = 0
    public static let userError:         Int32 = 1
    public static let networkError:      Int32 = 2
    public static let engineNotFound:    Int32 = 3
    public static let videoUnavailable:  Int32 = 4
    public static let diskPermission:    Int32 = 5

    public static func forErrorCode(_ code: VvxErrorCode) -> Int32 {
        switch code {
        case .videoUnavailable:             return videoUnavailable
        case .platformUnsupported:          return userError
        case .engineNotFound:               return engineNotFound
        case .ffmpegNotFound:               return engineNotFound
        case .networkError:                 return networkError
        case .rateLimited:                  return networkError
        case .diskFull, .permissionDenied:  return diskPermission
        case .invalidTimeRange:                              return userError
        case .parseError, .unknownError:                    return userError
        case .indexEmpty, .sqlInvalid:                      return userError
        case .indexCorrupt:                                 return diskPermission
        case .playlistUnavailable:                          return userError
        case .clipFailed:                                   return userError
        case .proRequired:                                  return userError
        case .nleNoLocalFiles:                              return userError
        case .nleWriteFailed:                               return diskPermission
        }
    }
}

// MARK: - Stderr classification

extension VvxError {
    /// Classify a yt-dlp stderr snippet into a typed VvxError.
    /// The `agentAction` field is automatically populated via the initializer default.
    public static func fromYtDlpStderr(_ stderr: String, url: String?) -> VvxError {
        let lower = stderr.lowercased()

        if lower.contains("sign in to confirm") || lower.contains("age-restricted")
            || lower.contains("private video") || lower.contains("this video is unavailable")
            || lower.contains("video unavailable") || lower.contains("has been removed") {
            return VvxError(
                code: .videoUnavailable,
                message: "This video is unavailable, private, or age-restricted.",
                url: url,
                detail: String(stderr.prefix(400))
            )
        }
        if lower.contains("urlopen error") || lower.contains("name resolution failed")
            || lower.contains("connection refused") || lower.contains("network unreachable") {
            return VvxError(
                code: .networkError,
                message: "Network error: could not reach the platform.",
                url: url,
                detail: String(stderr.prefix(400))
            )
        }
        if lower.contains("rate limit") || lower.contains("too many requests")
            || lower.contains("429") {
            return VvxError(
                code: .rateLimited,
                message: "The platform is rate-limiting requests.",
                url: url,
                detail: String(stderr.prefix(400))
            )
        }
        if lower.contains("unsupported url") || lower.contains("no suitable extractor") {
            return VvxError(
                code: .platformUnsupported,
                message: "This URL is not supported by yt-dlp.",
                url: url,
                detail: String(stderr.prefix(400))
            )
        }
        if lower.contains("no space left") {
            return VvxError(
                code: .diskFull,
                message: "Disk is full.",
                url: url,
                detail: String(stderr.prefix(400))
            )
        }
        return VvxError(
            code: .unknownError,
            message: "yt-dlp exited with an error.",
            url: url,
            detail: String(stderr.prefix(400))
        )
    }
}
