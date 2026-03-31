import Foundation
import VideoVortexCore

// MARK: - Tool error

enum McpToolError: Error, LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case engineNotFound
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):      return "Unknown tool: \(name)"
        case .missingArgument(let arg):   return "Missing required argument: \(arg)"
        case .engineNotFound:             return "yt-dlp not found. Install with: brew install yt-dlp (macOS) or pip install yt-dlp (all platforms)."
        case .executionFailed(let msg):   return msg
        }
    }
}

// MARK: - Tool registry

/// Holds tool definitions and dispatches `tools/call` requests to implementations.
final class McpToolRegistry: Sendable {

    // MARK: - Tool definitions (returned by tools/list)

    func toolDefinitions() -> [[String: Any]] {
        [
            senseDefinition,
            fetchDefinition,
            searchDefinition,
            syncDefinition,
            clipDefinition,
            gatherDefinition,
            ingestDefinition,
            libraryDefinition,
            sqlDefinition,
            reindexDefinition,
            doctorDefinition,
        ]
    }

    // MARK: - Dispatch

    func call(tool: String, arguments: [String: Any]) async throws -> String {
        switch tool {
        case "sense":   return try await SenseTool.call(arguments: arguments)
        case "fetch":   return try await FetchTool.call(arguments: arguments)
        case "search":  return try await SearchTool.call(arguments: arguments)
        case "sync":    return try await SyncTool.call(arguments: arguments)
        case "clip":    return try await ClipTool.call(arguments: arguments)
        case "gather":  return try await GatherTool.call(arguments: arguments)
        case "ingest":  return try await IngestTool.call(arguments: arguments)
        case "library": return try await LibraryTool.call(arguments: arguments)
        case "sql":     return try await SqlTool.call(arguments: arguments)
        case "reindex": return try await ReindexTool.call(arguments: arguments)
        case "doctor":  return try await DoctorTool.call(arguments: arguments)
        default:        throw McpToolError.unknownTool(tool)
        }
    }

    // MARK: - Tool schemas

    private var senseDefinition: [String: Any] {[
        "name": "sense",
        "description": """
        Extract structured metadata and transcript from any video URL — no media download. \
        Returns schemaVersion 3.0 JSON with: title, uploader, duration, tags, chapter outline \
        (with endTime and estimatedTokens per chapter), transcriptSource, estimatedTokens, \
        and inline transcriptBlocks (timestamped, cleaned, with chapterIndex). \
        For short videos, transcriptBlocks gives you the full transcript in one call. \
        For long videos: set metadataOnly=true to plan context usage first, then call again \
        with start/end to retrieve specific sections. \
        Sliced outputs include sliced:true, sliceStart, and sliceEnd fields. \
        Supports private/age-restricted videos and sponsor-block removal.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "The video URL (YouTube, TikTok, X, Instagram, Vimeo, and 1000+ more)"
                ],
                "outputFormat": [
                    "type": "string",
                    "enum": ["json", "transcript", "markdown"],
                    "default": "json"
                ],
                "cookiesFromBrowser": [
                    "type": "string",
                    "enum": ["safari", "chrome", "arc", "firefox", "none"],
                    "default": "none",
                    "description": "Borrow browser cookies to access age-restricted or private content"
                ],
                "noSponsors": [
                    "type": "boolean",
                    "default": false,
                    "description": "Strip SponsorBlock sponsor segments from the transcript (requires ffmpeg)"
                ],
                "metadataOnly": [
                    "type": "boolean",
                    "default": false,
                    "description": "Return metadata and token counts only — strips transcriptBlocks from the response. estimatedTokens and per-chapter estimatedTokens are still populated. Use for very long videos: call with metadataOnly=true first, then sense specific sections with start/end."
                ],
                "start": [
                    "type": "string",
                    "description": "Transcript slice start. Accepts HH:MM:SS, MM:SS, or decimal seconds. Defaults to 0 when omitted. The full transcript is always indexed to vortex.db; only the JSON output is sliced."
                ],
                "end": [
                    "type": "string",
                    "description": "Transcript slice end. Accepts HH:MM:SS, MM:SS, or decimal seconds. Open-ended when omitted."
                ]
            ],
            "required": ["url"]
        ]
    ]}

    private var fetchDefinition: [String: Any] {[
        "name": "fetch",
        "description": """
        Download a video file and its metadata to the local archive. Returns absolute file \
        paths for all generated files (MP4, SRT, JSON sidecar). \
        Supports private/age-restricted videos and sponsor-block removal. \
        Use videoPath from the result as inputPath when chaining to the clip tool.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "url": ["type": "string"],
                "archive": [
                    "type": "boolean",
                    "default": false,
                    "description": "Creates a full structured project folder with all sidecars (MP4 + SRT + .info.json + thumbnail)"
                ],
                "format": [
                    "type": "string",
                    "enum": ["best", "1080p", "720p", "broll", "mp3", "reactionkit"],
                    "default": "best",
                    "description": "Video quality / format. Use 'mp3' for audio-only, 'broll' for muted video, 'reactionkit' for video+audio+subs."
                ],
                "cookiesFromBrowser": [
                    "type": "string",
                    "enum": ["safari", "chrome", "arc", "firefox", "none"],
                    "default": "none",
                    "description": "Borrow browser cookies to access age-restricted or private content"
                ],
                "noSponsors": [
                    "type": "boolean",
                    "default": false,
                    "description": "Strip SponsorBlock sponsor segments from the downloaded media and transcript (requires ffmpeg)"
                ],
                "noAutoUpdate": [
                    "type": "boolean",
                    "default": false,
                    "description": "Deprecated no-op. yt-dlp is no longer auto-updated by vvx."
                ],
                "allSubs": [
                    "type": "boolean",
                    "default": false,
                    "description": "Request all English subtitle variants (en.*). Higher platform traffic; default is en,en-orig only."
                ]
            ],
            "required": ["url"]
        ]
    ]}

    private var searchDefinition: [String: Any] {[
        "name": "search",
        "description": """
        Full-text search, structural analysis, and proximity search across all indexed transcripts.

        MODES:
        • Standard FTS (default): Provide query + outputFormat.
          outputFormat: "rag" = Markdown context for answering questions; "json" = structured SearchOutput for pipelines.
        • Structural (no query needed): Set longestMonologue OR highDensity.
          Returns top N spans sorted by duration (monologue) or words-per-second (density). Always JSON.
        • Proximity: Provide query with explicit AND + set within (seconds).
          Returns the tightest window where all terms co-occur, sorted ascending by proximitySpanSeconds.
          Always JSON. structuralScore = proximitySpanSeconds — LOWER is better.

        All structural/proximity result lines include videoId, transcriptExcerpt (≤ 1,000 chars), and
        reproduceCommand. Pass transcriptExcerpt to an LLM to evaluate fit before calling gather.
        Results are pre-sorted; agents should consume them in order without re-sorting.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "FTS5 query. Supports AND, OR, NOT, phrase search (quoted), and prefix wildcard (word*). Optional when longestMonologue or highDensity is set."
                ],
                "outputFormat": [
                    "type": "string",
                    "enum": ["json", "rag"],
                    "description": "Required for standard FTS. Ignored for structural/proximity (always returns JSON). 'rag' for human-readable Markdown with clip commands; 'json' for structured data."
                ],
                "limit": [
                    "type": "integer",
                    "default": 50,
                    "description": "Maximum number of results."
                ],
                "platform": [
                    "type": "string",
                    "description": "Filter by platform (e.g. YouTube, TikTok, Twitter)."
                ],
                "after": [
                    "type": "string",
                    "description": "Only include videos uploaded on or after this date (YYYY-MM-DD)."
                ],
                "uploader": [
                    "type": "string",
                    "description": "Filter by uploader or channel name (exact match)."
                ],
                "maxTokens": [
                    "type": "integer",
                    "description": "Maximum estimated tokens for rag output. Truncates hits before exceeding budget. Requires outputFormat='rag'."
                ],
                "longestMonologue": [
                    "type": "boolean",
                    "default": false,
                    "description": "Find the longest continuous speech spans across all indexed videos. No query needed. Returns MonologueResultLine NDJSON sorted by duration descending."
                ],
                "highDensity": [
                    "type": "boolean",
                    "default": false,
                    "description": "Find the highest words-per-second windows across all indexed videos. No query needed. Returns DensityResultLine NDJSON sorted by wordsPerSecond descending."
                ],
                "monologueGap": [
                    "type": "number",
                    "default": 1.5,
                    "description": "Maximum silence gap (seconds) allowed between transcript blocks within the same monologue span. Used with longestMonologue."
                ],
                "densityWindow": [
                    "type": "number",
                    "default": 60.0,
                    "description": "Sliding window width in seconds for high-density analysis. Used with highDensity."
                ],
                "within": [
                    "type": "number",
                    "description": "Proximity window in seconds. Requires query with at least two explicit AND terms. Returns the tightest co-occurrence window; must be > 0."
                ]
            ],
            "required": []
        ]
    ]}

    private var syncDefinition: [String: Any] {[
        "name": "sync",
        "description": """
        Ingest a channel, playlist, or collection URL into the local archive. \
        Resolves all video URLs via yt-dlp, then senses (or archives) each one concurrently \
        with up to 3 workers. Every success is indexed into vortex.db. \
        Returns aggregated NDJSON output (one line per video) in a single response. \
        \n\
        TIMEOUT WARNING: MCP tool calls block until the batch finishes. Many MCP clients \
        enforce a maximum duration (often ~60 seconds, but host-specific). Keep limit small \
        (5–20 for sense-only; lower for archive=true or slow networks) to stay within budget. \
        For large channels or full backfills, have the user run 'vvx sync …' in Terminal instead — \
        there is no timeout on the CLI. \
        \n\
        Strongly prefer incremental=true when re-syncing channels so only new videos are processed.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "Channel (@handle), playlist URL, or collection URL."
                ],
                "limit": [
                    "type": "integer",
                    "description": "REQUIRED. Maximum videos to process. Keep small (5–20) to avoid MCP client timeouts."
                ],
                "incremental": [
                    "type": "boolean",
                    "default": false,
                    "description": "Skip videos already in vortex.db (sensed_at IS NOT NULL). Strongly recommended for repeat channel runs."
                ],
                "archive": [
                    "type": "boolean",
                    "default": false,
                    "description": "Download MP4 + sidecars to vault instead of sense-only. Use a smaller limit when true."
                ],
                "metadataOnly": [
                    "type": "boolean",
                    "default": false,
                    "description": "Return metadata and token counts only — omits transcriptBlocks from NDJSON output."
                ],
                "noAutoUpdate": [
                    "type": "boolean",
                    "default": false,
                    "description": "Deprecated no-op. yt-dlp is no longer auto-updated by vvx."
                ],
                "force": [
                    "type": "boolean",
                    "default": false,
                    "description": "Force re-sync even if incremental=true."
                ],
                "allSubs": [
                    "type": "boolean",
                    "default": false,
                    "description": "Request all English subtitle variants. Higher platform traffic."
                ],
                "matchTitle": [
                    "type": "string",
                    "description": "Only sync videos whose title matches this regex (passed to yt-dlp --match-title)."
                ],
                "afterDate": [
                    "type": "string",
                    "description": "Only sync videos on or after this date. Accepts YYYYMMDD, '7d', 'today', etc."
                ]
            ],
            "required": ["url", "limit"]
        ]
    ]}

    private var clipDefinition: [String: Any] {[
        "name": "clip",
        "description": """
        Extract a precise video segment as an MP4 file from a local video. \
        Default mode is frame-accurate (re-encode); set fast=true for instant keyframe-seek \
        stream copy at ±2-5s drift. Requires ffmpeg. Headless: no interactive prompts. \
        Use inputPath from a fetch or library result; use start/end from a search result's \
        timestamp fields to chain the search → clip workflow.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "inputPath": [
                    "type": "string",
                    "description": "Absolute path to the source video file."
                ],
                "start": [
                    "type": "string",
                    "description": "Start time. Accepts HH:MM:SS, MM:SS, or decimal seconds."
                ],
                "end": [
                    "type": "string",
                    "description": "End time. Accepts HH:MM:SS, MM:SS, or decimal seconds."
                ],
                "fast": [
                    "type": "boolean",
                    "default": false,
                    "description": "Fast mode: keyframe seek + stream copy. Instant but ±2-5s drift."
                ],
                "output": [
                    "type": "string",
                    "description": "Optional output file path. Default: smart timestamp-named file alongside the input."
                ]
            ],
            "required": ["inputPath", "start", "end"]
        ]
    ]}

    private var gatherDefinition: [String: Any] {[
        "name": "gather",
        "description": """
        Batch-extract clips from your local vortex.db archive as frame-accurate MP4 files. \
        Searches indexed transcripts or chapter titles, resolves clip windows, and runs up to \
        4 concurrent ffmpeg extractions. Writes per-clip re-timed SRT subtitles, manifest.json, \
        and clips.md to an auto-named output folder on ~/Desktop.

        TIMEOUT WARNING: Each clip takes 5–60 seconds depending on length and encode mode. \
        For batches > 5 clips, use dryRun=true first to preview planned clips, then re-call \
        without dryRun. For very large batches (>20 clips), have the user run 'vvx gather …' \
        in Terminal — no timeout on the CLI.

        PRO FEATURE: gather is a Pro feature. During Public Beta (Step 11 not yet shipped), \
        all users may use gather freely.

        The last NDJSON line is always a summary with outputDir and manifestPath. \
        manifestPath is null for dry-runs or zero-success runs. \
        Partial failures appear as success:false lines — the run does not abort on one failure. \
        Agents should present manifestPath to the user as the handoff artifact for NLE editors.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "FTS5 query. Required. Supports AND, OR, NOT, phrase (quoted), prefix*."
                ],
                "limit": [
                    "type": "integer",
                    "description": "REQUIRED. Max clips to extract. Keep ≤ 5 for live extraction to avoid MCP timeouts."
                ],
                "dryRun": [
                    "type": "boolean",
                    "default": false,
                    "description": "Plan-only: skip ffmpeg, return planned paths and timing."
                ],
                "platform": [
                    "type": "string",
                    "description": "Filter by platform (e.g. YouTube, TikTok)."
                ],
                "after": [
                    "type": "string",
                    "description": "Only include videos uploaded on or after YYYY-MM-DD."
                ],
                "uploader": [
                    "type": "string",
                    "description": "Filter by uploader or channel name (exact match)."
                ],
                "minViews": [
                    "type": "integer",
                    "description": "Only gather clips from videos with at least this many views."
                ],
                "minLikes": [
                    "type": "integer",
                    "description": "Only gather clips from videos with at least this many likes."
                ],
                "minComments": [
                    "type": "integer",
                    "description": "Only gather clips from videos with at least this many comments."
                ],
                "contextSeconds": [
                    "type": "number",
                    "default": 1.0,
                    "description": "Seconds before/after matched cue. Ignored with snap block/chapter."
                ],
                "snap": [
                    "type": "string",
                    "enum": ["off", "block", "chapter"],
                    "default": "off",
                    "description": "off=cue+context; block=exact cue bounds; chapter=full chapter span."
                ],
                "maxTotalDuration": [
                    "type": "number",
                    "description": "Hard cap on total clip seconds. Lower-relevance clips dropped first."
                ],
                "pad": [
                    "type": "number",
                    "default": 2.0,
                    "description": "NLE handle seconds before/after logical in/out. Clamped at 0."
                ],
                "fast": [
                    "type": "boolean",
                    "default": false,
                    "description": "Keyframe seek + stream copy. Instant but ±2–5 s drift."
                ],
                "exact": [
                    "type": "boolean",
                    "default": false,
                    "description": "libx264 CRF 18 re-encode — frame-accurate, slow. Mutually exclusive with fast."
                ],
                "thumbnails": [
                    "type": "boolean",
                    "default": false,
                    "description": "Extract one JPEG still per clip at logical clip start."
                ],
                "embedSource": [
                    "type": "boolean",
                    "default": false,
                    "description": "Embed source URL, title, and uploader into MP4 metadata atoms."
                ],
                "chaptersOnly": [
                    "type": "boolean",
                    "default": false,
                    "description": "Search chapter titles; extract full chapter spans. Implies snap=chapter."
                ]
            ],
            "required": ["query", "limit"]
        ]
    ]}

    private var ingestDefinition: [String: Any] {[
        "name": "ingest",
        "description": """
        Index local video files into vortex.db without moving or copying them. \
        Recursively scans a folder for video files (.mp4 by default), matches sibling \
        sidecars in the same directory (.srt for transcript, .info.json for yt-dlp-style \
        metadata), and indexes each file using its absolute path. \
        \n\
        Sidecars must share the video's filename stem and directory. \
        .en.srt (or .srt) → transcript_source "local". .info.json → title, uploader, etc. \
        \n\
        Returns NDJSON: one result line per video (indexed or skipped), ending with a \
        type: "summary" line containing: indexed, skipped, skipped_reasons \
        (keys non_video / invalid_sidecar / corrupt_media / already_indexed — all always \
        present as integers ≥ 0), and malformed_info_json_count (always present). \
        \n\
        Agents should prefer dryRun=true on unfamiliar folder trees first to preview \
        without writing to vortex.db or running any probes. \
        With dryRun=true the summary line will include "dry_run":true. \
        Partial failures (per-file) appear as success:false lines — the run never aborts \
        on a single bad file. Fatal errors (path not found, not a directory) return a \
        VvxErrorEnvelope.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or relative path to the root folder to scan. Resolved to absolute before any DB write."
                ],
                "dryRun": [
                    "type": "boolean",
                    "default": false,
                    "description": "Walk the folder and match sidecars without writing to vortex.db or running ffprobe. Recommended for previewing large or unfamiliar trees."
                ],
                "forceReindex": [
                    "type": "boolean",
                    "default": false,
                    "description": "Bypass dedup check and re-upsert metadata for files already indexed in vortex.db."
                ]
            ],
            "required": ["path"]
        ]
    ]}

    private var libraryDefinition: [String: Any] {[
        "name": "library",
        "description": """
        List all indexed/archived videos from vortex.db. \
        Returns aggregated NDJSON (one VideoRecord per line). \
        Each record includes id (canonical URL), title, platform, uploader, durationSeconds, \
        sensedAt, videoPath (nil for sense-only), and transcriptPath. \
        Use videoPath as inputPath when chaining to the clip tool.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "downloaded": [
                    "type": "boolean",
                    "default": false,
                    "description": "Only return videos that have a downloaded MP4 file on disk."
                ],
                "platform": [
                    "type": "string",
                    "description": "Filter by platform (e.g. YouTube, TikTok)."
                ],
                "uploader": [
                    "type": "string",
                    "description": "Filter by uploader or channel name (exact match)."
                ],
                "limit": [
                    "type": "integer",
                    "description": "Maximum number of results."
                ],
                "sort": [
                    "type": "string",
                    "enum": ["newest", "oldest", "title", "duration"],
                    "default": "newest"
                ]
            ],
            "required": []
        ]
    ]}

    private var sqlDefinition: [String: Any] {[
        "name": "sql",
        "description": """
        Run a read-only SELECT query against ~/.vvx/vortex.db for metadata analytics. \
        ONLY SELECT statements are permitted — the connection is opened OS-level read-only. \
        Returns structured JSON with rows and rowCount. \
        \n\
        Schema cheat sheet: \
        • videos — id (URL), title, platform, uploader, duration_seconds, upload_date, \
          sensed_at, archived_at, transcript_path, video_path, view_count, \
          like_count (null pre-Phase3 or unsupported platform), \
          comment_count (null pre-Phase3 or unsupported platform), \
          description, chapters (JSON array) \
        • transcript_blocks — video_id, block_index, start_seconds, end_seconds, \
          start_time, end_time, text, word_count, estimated_tokens, chapter_index \
        \n\
        Example queries: \
        SELECT uploader, COUNT(*) AS videos FROM videos GROUP BY uploader ORDER BY videos DESC LIMIT 5 \
        SELECT COUNT(*) AS total, SUM(duration_seconds)/3600 AS hours FROM videos \
        SELECT title, sensed_at FROM videos ORDER BY sensed_at DESC LIMIT 10
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "A single SELECT statement. Only SELECT is allowed."
                ]
            ],
            "required": ["query"]
        ]
    ]}

    private var reindexDefinition: [String: Any] {[
        "name": "reindex",
        "description": """
        Rebuild transcript_blocks in vortex.db, backfilling chapter_index for all videos. \
        Fully idempotent — safe to run multiple times. \
        Run after upgrading to schema v3 or any time transcript data has been edited manually. \
        Returns aggregated NDJSON (one line per video, plus a summary line) in a single response. \
        Use dryRun=true to preview without writing to the database.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "dryRun": [
                    "type": "boolean",
                    "default": false,
                    "description": "Preview what would be reindexed without writing to the database."
                ]
            ],
            "required": []
        ]
    ]}

    private var doctorDefinition: [String: Any] {[
        "name": "doctor",
        "description": """
        Diagnose the vvx environment. CALL THIS TOOL AUTOMATICALLY whenever sense, fetch, \
        or any other vvx tool returns an error — do not ask the user for help first. \
        Returns structured JSON with: status ("ok"|"degraded"|"critical"), \
        binaryVersionMatchesDocs (true/false), lastEngineUpdate, daysSinceEngineUpdate, \
        a checks array (each check has name, passed, detail, and optionally fixCommand + \
        requiresManual), a top-level fixes array, and when ~/.vvx/vortex.db exists an \
        archive object (videoCount, estimatedHours, lastSyncedAt, dbPath, dbStatus). \
        For each fix: requiresManual=false means you can apply it automatically; \
        requiresManual=true means present it to the user. \
        If status is "critical" (engine missing), follow the fixCommand in the engine check \
        to install yt-dlp via the system package manager (e.g. brew install yt-dlp). \
        requiresManual=true items must be presented to the user; you cannot apply them automatically.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [:]
        ]
    ]}
}
