import Foundation

// MARK: - Ingest NDJSON models (Core — shared by CLI and MCP)

// MARK: - Skip reasons

/// Canonical skip reasons for `IngestResultLine.skipReason` and the `skipped_reasons`
/// keys in `IngestSummaryLine`. All four keys are always emitted in the summary (even at 0).
public enum IngestSkipReason: String, Sendable {
    case nonVideo       = "non_video"
    case alreadyIndexed = "already_indexed"
    case invalidSidecar = "invalid_sidecar"
    case corruptMedia   = "corrupt_media"
}

// MARK: - Per-video result line

/// One result line per video candidate processed by `IngestEngine`.
///
/// Emitted for every video-extension file discovered, whether indexed or skipped.
/// Non-video files (extension mismatch) are counted only in the summary — they do not
/// produce individual result lines.
public struct IngestResultLine: Encodable, Sendable {
    public let success:          Bool
    public let path:             String
    public let videoId:          String?     // absolute path used as DB id; present on success
    public let title:            String?     // present on success
    public let durationSeconds:  Int?        // present when probed or read from info.json
    public let transcriptSource: String?     // "local" | "none" — present on success
    public let skipped:          Bool
    public let skipReason:       String?     // canonical IngestSkipReason.rawValue when skipped

    // MARK: - Factories

    public static func indexed(
        path:             String,
        videoId:          String,
        title:            String,
        durationSeconds:  Int?,
        transcriptSource: String
    ) -> IngestResultLine {
        IngestResultLine(
            success:          true,
            path:             path,
            videoId:          videoId,
            title:            title,
            durationSeconds:  durationSeconds,
            transcriptSource: transcriptSource,
            skipped:          false,
            skipReason:       nil
        )
    }

    public static func skipped(path: String, reason: IngestSkipReason) -> IngestResultLine {
        IngestResultLine(
            success:          false,
            path:             path,
            videoId:          nil,
            title:            nil,
            durationSeconds:  nil,
            transcriptSource: nil,
            skipped:          true,
            skipReason:       reason.rawValue
        )
    }

    // Private memberwise
    private init(
        success: Bool, path: String, videoId: String?, title: String?,
        durationSeconds: Int?, transcriptSource: String?,
        skipped: Bool, skipReason: String?
    ) {
        self.success          = success
        self.path             = path
        self.videoId          = videoId
        self.title            = title
        self.durationSeconds  = durationSeconds
        self.transcriptSource = transcriptSource
        self.skipped          = skipped
        self.skipReason       = skipReason
    }

    enum CodingKeys: String, CodingKey {
        case success, path, videoId = "video_id", title
        case durationSeconds  = "duration_seconds"
        case transcriptSource = "transcript_source"
        case skipped, skipReason = "skip_reason"
    }
}

// MARK: - Skipped-reasons map

/// All four canonical `skipped_reasons` keys — always emitted including zeros.
///
/// `non_video`:       files whose extension is not in the ingest allowlist.
/// `already_indexed`: video candidates already present in `vortex.db` (dedup; no `--force-reindex`).
/// `invalid_sidecar`: companion `.srt` or `.info.json` present but unreadable or unparseable.
/// `corrupt_media`:   video candidate could not be written to `vortex.db` (e.g. DB error).
public struct IngestSkippedReasons: Encodable, Sendable {
    public let nonVideo:       Int
    public let alreadyIndexed: Int
    public let invalidSidecar: Int
    public let corruptMedia:   Int

    public init(nonVideo: Int, alreadyIndexed: Int, invalidSidecar: Int, corruptMedia: Int) {
        self.nonVideo       = nonVideo
        self.alreadyIndexed = alreadyIndexed
        self.invalidSidecar = invalidSidecar
        self.corruptMedia   = corruptMedia
    }

    enum CodingKeys: String, CodingKey {
        case nonVideo       = "non_video"
        case alreadyIndexed = "already_indexed"
        case invalidSidecar = "invalid_sidecar"
        case corruptMedia   = "corrupt_media"
    }
}

// MARK: - Summary line

/// Final line always emitted by `IngestEngine.run()`.
///
/// CLI: last NDJSON line on stdout; agents detect it via `"type":"summary"`.
/// MCP: returned as part of the NDJSON blob; agent reads `indexed` / `skipped_reasons`
/// and `malformed_info_json_count` from this line.
///
/// All `skipped_reasons` keys are always emitted (integer ≥ 0).
/// `malformed_info_json_count` is always emitted (integer ≥ 0).
public struct IngestSummaryLine: Encodable, Sendable {
    public let success:                Bool   = true
    public let type:                   String = "summary"
    public let indexed:                Int
    public let skipped:                Int
    public let skippedReasons:         IngestSkippedReasons
    public let malformedInfoJsonCount: Int
    public let errorsLogged:           Int
    public let dryRun:                 Bool

    public init(
        indexed:               Int,
        skipped:               Int,
        skippedReasons:        IngestSkippedReasons,
        malformedInfoJsonCount: Int,
        errorsLogged:          Int,
        dryRun:                Bool
    ) {
        self.indexed                = indexed
        self.skipped                = skipped
        self.skippedReasons         = skippedReasons
        self.malformedInfoJsonCount = malformedInfoJsonCount
        self.errorsLogged           = errorsLogged
        self.dryRun                 = dryRun
    }

    enum CodingKeys: String, CodingKey {
        case success, type, indexed, skipped, dryRun = "dry_run"
        case skippedReasons         = "skipped_reasons"
        case malformedInfoJsonCount = "malformed_info_json_count"
        case errorsLogged           = "errors_logged"
    }
}
