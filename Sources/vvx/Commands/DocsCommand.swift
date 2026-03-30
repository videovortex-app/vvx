import ArgumentParser
import Foundation
import VideoVortexCore

// MARK: - DocsCommand

struct DocsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docs",
        abstract: "Print LLM-optimized reference documentation to stdout.",
        discussion: """
        Outputs a structured Markdown reference written for AI agents, not humans.
        An agent that has never used vvx before should call `vvx docs` at the start
        of a session to load the full API surface into its context window.

        To avoid blowing up your context window, target a specific command:
          vvx docs sense        # only the sense command reference
          vvx docs fetch        # only the fetch command reference
          vvx docs doctor       # only the doctor command reference

        Content filters:
          vvx docs --errors     # error codes and agentAction recovery table only
          vvx docs --schema     # raw JSON Schema Draft-07 for all output types
          vvx docs --examples   # chaining patterns and worked examples only
        """
    )

    // MARK: - Canonical version

    /// Same as `vvxDocsVersion` in VvxVersion.swift.
    static let docsVersion = vvxDocsVersion

    // MARK: - Arguments & flags

    @Argument(help: "Show docs for a specific command: sense, fetch, search, sync, clip, library, sql, reindex, doctor, engine")
    var topic: String?

    @Flag(name: .long, help: "Print error codes and agentAction recovery table only.")
    var errors: Bool = false

    @Flag(name: .long, help: "Print raw JSON Schema Draft-07 for all output types (pipe-ready).")
    var schema: Bool = false

    @Flag(name: .long, help: "Print chaining patterns and worked examples only.")
    var examples: Bool = false

    // MARK: - Entry point

    func run() async throws {
        if schema {
            print(jsonSchema)
            return
        }
        if errors {
            print(errorsSection)
            return
        }
        if examples {
            print(examplesSection)
            return
        }
        if let t = topic?.lowercased() {
            switch t {
            case "sense":                    print(senseSection)
            case "fetch":                    print(fetchSection)
            case "search":                   print(searchSection)
            case "sync":                     print(syncSection)
            case "clip":                     print(clipSection)
            case "library", "lib":           print(librarySection)
            case "sql":                      print(sqlSection)
            case "reindex", "re":            print(reindexSection)
            case "doctor", "doc":            print(doctorSection)
            case "engine":                   print(engineSection)
            case "errors", "error":          print(errorsSection)
            case "examples", "ex":           print(examplesSection)
            default:
                fputs("Unknown topic '\(t)'. Valid topics: sense, fetch, search, sync, clip, library, sql, reindex, doctor, engine, errors, examples\n", stderr)
                throw ExitCode.failure
            }
            return
        }
        // Full reference
        print(fullReference)
    }
}

// MARK: - Full reference

private extension DocsCommand {
    var fullReference: String {
        """
        # vvx — Agent Reference Manual
        **Version:** \(DocsCommand.docsVersion)
        **Written for:** AI agents. Tone: precise, no marketing.
        **What it does:** Turns any video URL into structured JSON + full transcript
        without downloading the media file.

        \(senseSection)

        \(fetchSection)

        \(searchSection)

        \(syncSection)

        \(clipSection)

        \(librarySection)

        \(sqlSection)

        \(reindexSection)

        \(engineSection)

        \(doctorSection)

        \(errorsSection)

        \(examplesSection)
        """
    }
}

// MARK: - Section: sense

private extension DocsCommand {
    var senseSection: String {
        """
        ## sense — Extract metadata + transcript (no download)

        The hero command. Use this for every "read a video" request.
        Zero media download. Returns JSON to stdout + writes .srt to disk.

        ### Usage
        ```
        vvx sense <url>
        vvx sense <url> --transcript            # raw SRT text to stdout
        vvx sense <url> --markdown              # formatted Markdown document
        vvx sense <url> --metadata-only         # metadata + token budget; no transcript blocks
        vvx sense <url> --start HH:MM:SS --end HH:MM:SS  # time-range slice
        vvx sense <url> --browser safari        # access private/age-restricted content
        vvx sense <url> --no-sponsors           # strip SponsorBlock segments (requires ffmpeg)
        vvx <url>                               # shorthand (sense is the default)
        ```

        ### Output schema (JSON to stdout) — SenseResult v3
        ```json
        {
          "schemaVersion": "3.0",
          "success": true,
          "url": "https://...",
          "title": "Video Title",
          "platform": "YouTube",
          "uploader": "Channel Name",
          "durationSeconds": 347,
          "uploadDate": "2026-01-15",
          "description": "Full description text (not truncated).",
          "descriptionTruncated": false,
          "tags": ["tag1", "tag2"],
          "viewCount": 1482930,
          "likeCount": 48320,
          "commentCount": 3210,
          "transcriptSource": "manual",
          "transcriptLanguage": "en",
          "estimatedTokens": 3420,
          "transcriptBlocks": [
            {
              "index": 1,
              "startSeconds": 0.0,
              "endSeconds": 3.5,
              "text": "Welcome to the show.",
              "wordCount": 4,
              "estimatedTokens": 5,
              "chapterIndex": 0
            }
          ],
          "chapters": [
            {
              "title": "Introduction",
              "startTime": 0,
              "startTimeFormatted": "0:00",
              "endTime": 183.0,
              "estimatedTokens": 890
            }
          ],
          "transcriptPath": "/Users/you/.vvx/transcripts/YouTube/Channel/Title.en.srt",
          "completedAt": "2026-03-24T10:30:00Z"
        }
        ```

        ### `--metadata-only` mode
        `transcriptBlocks` is empty but `estimatedTokens` and all chapter token counts are
        populated. Use this on long videos to plan token usage before fetching full blocks.
        Follow up with `--start`/`--end` or `vvx search` to retrieve specific sections.

        ### Slicing fields (--start / --end)
        When either flag is used, the output also includes:
        - `"sliced": true`
        - `"sliceStart"`: start seconds (null = open)
        - `"sliceEnd"`: end seconds (null = open)
        Top-level `estimatedTokens` and chapter token sums are recalculated for the slice only.

        ### `transcriptSource` values
        `manual` (most reliable) | `auto` (generated) | `community` | `none` | `unknown`
        Stop processing if `transcriptSource == "none"` — no usable transcript is available.

        ### Agent rules for sense
        1. **Check `estimatedTokens` first.**
           - `estimatedTokens < 8000`: use `transcriptBlocks` directly.
           - `estimatedTokens >= 8000`: call `--metadata-only` first to inspect chapters,
             then `--start`/`--end` for the relevant section, or `vvx search`.
        2. `transcriptBlocks` is the primary transcript interface. `transcriptPath` is an
           escape hatch for raw SRT access.
        3. For private or age-restricted content: retry with `--browser safari`.
        4. On error: read the `agentAction` field and execute it before escalating.
        """
    }
}

// MARK: - Section: fetch

private extension DocsCommand {
    var fetchSection: String {
        """
        ## fetch — Download video file to local archive

        Use fetch when the user explicitly wants a file on disk.
        Do not use fetch when the user just wants to read or analyze a video — use sense instead.

        ### Usage
        ```
        vvx fetch <url>
        vvx fetch <url> --archive             # full project folder: MP4 + SRT + .info.json + thumbnail
        vvx fetch <url> --format audio        # MP3 extract only
        vvx fetch <url> --format broll        # video-only, no audio track
        vvx fetch <url> --browser safari      # access private/age-restricted content
        vvx fetch <url> --no-sponsors         # strip SponsorBlock segments (requires ffmpeg)
        vvx fetch <url> --json                # print VideoMetadata JSON to stdout on completion
        vvx fetch --batch urls.txt            # batch file (one URL per line), NDJSON output
        cat urls.txt | vvx fetch              # stdin pipe, NDJSON output
        ```

        ### Formats
        | Flag value | Result |
        |------------|--------|
        | `best` (default) | Best available quality MP4 |
        | `broll` | Video-only stream (no audio), for B-roll use |
        | `audio` | MP3 audio extract |

        ### Output schema (JSON with --json flag)
        ```json
        {
          "id": "uuid",
          "url": "https://...",
          "title": "Video Title",
          "platform": "YouTube",
          "resolution": "1920x1080",
          "durationSeconds": 347,
          "fileSize": 104857600,
          "outputPath": "/Users/you/.vvx/downloads/YouTube/Channel/Title.mp4",
          "subtitlePaths": ["/Users/you/.vvx/.../Title.en.srt"],
          "format": "bestVideo",
          "isArchiveMode": false,
          "completedAt": "2026-03-24T10:30:00Z"
        }
        ```

        ### Batch output (NDJSON — one object per line)
        Each completed URL streams one JSON object. Failures emit the standard error envelope.
        """
    }
}

// MARK: - Section: search

private extension DocsCommand {
    var searchSection: String {
        """
        ## search — Full-text search across indexed transcripts

        Searches the FTS5 transcript index in `vortex.db`. Returns ranked hits with
        surrounding context. Requires at least one video to be indexed first (via `sense`,
        `fetch`, or `sync`).

        ### Usage
        ```
        vvx search "query"
        vvx search "query" --rag                        # structured Markdown for direct answer
        vvx search "AI AND safety"                      # boolean AND
        vvx search "\\"exact phrase\\""                 # phrase search
        vvx search "intell*"                            # prefix search
        vvx search "query" --max-tokens 5000            # token-budget cap for --rag output
        vvx search "query" --limit 20                   # max hits (default: 10)
        vvx search "query" --platform YouTube           # filter by platform
        vvx search "query" --after 2026-01-01           # filter by upload date
        vvx search "query" --uploader "Channel Name"    # filter by uploader
        ```

        ### JSON output schema (`vvx search "query"`)
        ```json
        {
          "success": true,
          "query": "artificial intelligence",
          "totalHits": 7,
          "results": [
            {
              "videoId": "https://youtube.com/watch?v=...",
              "title": "Video Title",
              "uploader": "Channel Name",
              "platform": "YouTube",
              "uploadDate": "2026-01-15",
              "videoPath": "/absolute/path/to/video.mp4",
              "transcriptPath": "/absolute/path/to/file.en.srt",
              "timestamp": "00:14:32",
              "timestampEnd": "00:14:47",
              "startSeconds": 872.0,
              "endSeconds": 887.0,
              "text": "...matched transcript snippet...",
              "relevanceScore": 0.93,
              "chapterTitle": "Chapter Name"
            }
          ]
        }
        ```

        ### `--rag` output
        Returns a single structured Markdown document with attribution, suitable for
        answering a user question directly. Respects `--max-tokens` budget: output is
        truncated by relevance (highest-scoring hits first) once the limit is reached.

        Token estimation: `wordCount × 1.3`. The `--max-tokens` budget is applied to
        the full RAG document; individual hit tokens are summed cumulatively.

        ### NLE export (Pro)
        Export a search result to Final Cut Pro (FCPXML), Premiere Pro (XMEML), or DaVinci Resolve (EDL) —
        zero re-encode, infinite handles. References archive files on disk in-place.

        ```
        vvx search "neuralink" --export-nle fcpx     --export-nle-out ~/Desktop/cuts.fcpxml
        vvx search "neuralink" --export-nle premiere --export-nle-out ~/Desktop/cuts.xml
        vvx search "neuralink" --export-nle resolve  --export-nle-out ~/Desktop/cuts.edl
        vvx search "neuralink" --export-nle fcpx     --export-nle-out ~/Desktop/cuts.fcpxml --dry-run
        ```

        Formats:
        - `fcpx` → FCPXML 1.9 for Final Cut Pro (drag-and-drop import).
        - `premiere` → XMEML v4 for Adobe Premiere Pro (File → Import).
        - `resolve` → CMX 3600 EDL for DaVinci Resolve (File → Import Timeline → Pre-conformed EDL).

        NLE export formats include:
        - Clip names with uploader + transcript snippet (readable from timeline at any zoom).
        - Chapter markers on the timeline when chapter data is present.
        - Matched text as clip comments/notes.

        NLE export final NDJSON line:
        ```json
        {"success":true,"format":"fcpx","outputPath":"/path/cuts.fcpxml","clipCount":8,"skippedCount":2,"totalDurationSeconds":142.5,"query":"neuralink","padSeconds":2.0,"reproduceCommand":"vvx search ..."}
        ```

        Clips with no local archive file are skipped (emit `NleSkipEntry` NDJSON + stderr warning).
        Run `vvx fetch "<url>" --archive` to download missing source videos, then retry.

        ### Agent rules for search
        - Use `--rag` when generating a user-facing answer from transcript content.
        - Use JSON output when chaining into `clip` — extract `videoPath`, `timestamp`,
          and `timestampEnd` from each hit.
        - `INDEX_EMPTY` error means no videos are indexed yet: run `vvx sync <url> --limit 10`.
        - For NLE export, source files must be on disk. Use `--dry-run` to check clip availability
          before writing the file.
        """
    }
}

// MARK: - Section: sync

private extension DocsCommand {
    var syncSection: String {
        """
        ## sync — Bulk ingest a channel or playlist

        Resolves a channel/playlist URL via yt-dlp, then senses (and optionally archives)
        each video. Streams NDJSON progress lines as each video completes.

        ### Usage
        ```
        vvx sync <url> --limit 20
        vvx sync <url> --limit 20 --incremental         # skip already-indexed URLs
        vvx sync <url> --limit 20 --archive             # also download full video + sidecars
        vvx sync <url> --limit 20 --match-title "AI"    # only process titles containing pattern
        vvx sync <url> --limit 20 --after-date 2026-01-01   # only videos uploaded after date
        vvx sync <url> --limit 20 --metadata-only       # no transcript blocks; planning data only
        ```

        ### Output (NDJSON — one object per line)
        Success line:
        ```json
        {"success":true,"schemaVersion":"3.0","url":"...","title":"...","transcriptSource":"manual","estimatedTokens":8420,"sensedAt":"2026-03-24T10:30:00Z"}
        ```
        Failure line:
        ```json
        {"success":false,"url":"...","error":{"code":"VIDEO_UNAVAILABLE","message":"...","agentAction":"..."}}
        ```

        ### Important: MCP timeout
        Many MCP clients enforce a short tool-call timeout (~60 s). For large syncs,
        run `vvx sync …` in Terminal instead of via MCP. Start with `--limit 5–20` when
        using MCP; use lower limits when `--archive` is true.

        ### Agent rules for sync
        - Always provide `--limit`. Never attempt unbounded sync.
        - Prefer `--incremental` when re-processing a channel to skip already-indexed videos.
        - Per-video errors in the output include `agentAction`; execute it before escalating.
        """
    }
}

// MARK: - Section: clip

private extension DocsCommand {
    var clipSection: String {
        """
        ## clip — Extract a video segment as MP4

        Cuts a precise segment from a local video file using ffmpeg. Requires ffmpeg
        installed (run `vvx doctor` to verify).

        ### Usage
        ```
        vvx clip <videoPath> --start HH:MM:SS --end HH:MM:SS
        vvx clip <videoPath> --start HH:MM:SS --end HH:MM:SS --fast   # keyframe seek (less precise)
        ```

        Time format: `HH:MM:SS`, `MM:SS`, or decimal seconds (e.g. `872.5`).

        ### Output schema (JSON to stdout)
        ```json
        {
          "success": true,
          "outputPath": "/absolute/path/to/clip_872s_887s.mp4",
          "startSeconds": 872.0,
          "endSeconds": 887.0,
          "method": "frame_accurate",
          "completedAt": "2026-03-24T10:30:00Z"
        }
        ```
        `method` is `"frame_accurate"` (default) or `"fast_copy"` (with `--fast`).

        ### Agent rules for clip
        - `FFMPEG_NOT_FOUND`: run `vvx doctor --auto-fix` to install ffmpeg, then retry.
        - `CLIP_FAILED`: retry with `--fast`; if still failing the video file may be corrupt.
        - Pair with `search` output: pass `videoPath`, `timestamp`, `timestampEnd` from a
          search hit directly into `clip`.
        """
    }
}

// MARK: - Section: library

private extension DocsCommand {
    var librarySection: String {
        """
        ## library — List all indexed/archived videos

        Queries the `videos` table in `vortex.db` and returns NDJSON. Includes all
        metadata fields including engagement counts captured at sense/fetch time.

        ### Usage
        ```
        vvx library
        vvx library --platform YouTube           # filter by platform
        vvx library --uploader "Channel Name"    # filter by uploader
        vvx library --downloaded                 # only videos with a local video file
        ```

        ### Output schema (NDJSON — one object per line)
        ```json
        {
          "id": "https://youtube.com/watch?v=...",
          "title": "Video Title",
          "platform": "YouTube",
          "uploader": "Channel Name",
          "durationSeconds": 347,
          "uploadDate": "2026-01-15",
          "transcriptPath": "/absolute/path/...",
          "videoPath": "/absolute/path/... | null",
          "sensedAt": "2026-03-24T10:30:00Z",
          "archivedAt": "2026-03-24T10:31:00Z | null",
          "tags": ["tag1"],
          "viewCount": 1482930,
          "likeCount": 48320,
          "commentCount": 3210,
          "description": "...",
          "chapters": [...]
        }
        ```

        **Engagement fields** (`likeCount`, `commentCount`) are snapshots captured at
        sense/fetch time. They are `null` for videos indexed before Phase 3, or on
        platforms that do not expose the data. Use `vvx sql` to query them analytically.
        """
    }
}

// MARK: - Section: sql

private extension DocsCommand {
    var sqlSection: String {
        """
        ## sql — Read-only analytics against vortex.db

        Executes a single SELECT statement against the local SQLite database.
        Only SELECT is permitted — mutations are rejected.

        ### Usage
        ```
        vvx sql "SELECT ..."
        vvx sql --schema                # print table and column definitions
        ```

        ### `videos` table columns
        | Column | Type | Description |
        |--------|------|-------------|
        | `id` | TEXT PK | Canonical URL |
        | `title` | TEXT | Video title |
        | `platform` | TEXT | e.g. "YouTube", "TikTok" |
        | `uploader` | TEXT | Channel name |
        | `upload_date` | TEXT | ISO 8601 date |
        | `duration_seconds` | INTEGER | Video length |
        | `transcript_path` | TEXT | Absolute path to .srt |
        | `video_path` | TEXT | Absolute path to media file; NULL if sense-only |
        | `sensed_at` | TEXT | ISO 8601 timestamp |
        | `archived_at` | TEXT | ISO 8601 timestamp; NULL if sense-only |
        | `tags` | TEXT | JSON array |
        | `view_count` | INTEGER | Snapshot at index time |
        | `like_count` | INTEGER | Snapshot at index time (null pre-Phase 3 or unavailable) |
        | `comment_count` | INTEGER | Snapshot at index time (null pre-Phase 3 or unavailable) |
        | `description` | TEXT | Full video description |
        | `chapters` | TEXT | JSON array of VideoChapter objects |

        ### `transcript_blocks` FTS5 table columns
        `video_id`, `title`, `platform`, `uploader`, `start_time`, `end_time`,
        `start_seconds`, `text`, `chapter_index`

        ### Example queries
        ```sql
        -- Top uploaders by video count
        SELECT uploader, COUNT(*) AS videos FROM videos
        GROUP BY uploader ORDER BY videos DESC LIMIT 10;

        -- Most-liked videos (Phase 3 engagement data)
        SELECT title, like_count, view_count FROM videos
        WHERE like_count IS NOT NULL ORDER BY like_count DESC LIMIT 10;

        -- Engagement ratio (likes per view) for viral analysis
        SELECT title, uploader,
               ROUND(CAST(like_count AS REAL) / view_count * 100, 2) AS like_pct
        FROM videos
        WHERE like_count IS NOT NULL AND view_count > 0
        ORDER BY like_pct DESC LIMIT 10;

        -- Videos with comments indexed
        SELECT title, comment_count FROM videos
        WHERE comment_count IS NOT NULL ORDER BY comment_count DESC LIMIT 10;
        ```

        ### Output schema (JSON to stdout)
        ```json
        {
          "success": true,
          "query": "SELECT ...",
          "rowCount": 5,
          "rows": [
            { "title": "...", "like_count": 48320 }
          ]
        }
        ```
        """
    }
}

// MARK: - Section: reindex

private extension DocsCommand {
    var reindexSection: String {
        """
        ## reindex — Rebuild the transcript index from disk

        Scans `~/.vvx/transcripts/` and `~/.vvx/archive/` for existing .srt files and
        re-populates `vortex.db`. Use this after upgrading vvx or if the database is
        missing or corrupt.

        ### Usage
        ```
        vvx reindex
        vvx reindex --dry-run    # show what would be indexed without writing
        ```

        ### Behavior
        - Streams progress to stderr as each file is processed.
        - Backfills `chapter_index` on `transcript_blocks` for legacy archives (Step 5.5).
        - Does **not** re-fetch yt-dlp metadata — engagement counts (`like_count`,
          `comment_count`) on pre-existing rows remain as-is; run a fresh `vvx sense`
          or `vvx fetch --archive` to capture current counts.
        - Idempotent: safe to run multiple times; duplicate entries are upserted.

        ### When to run
        - After `rm ~/.vvx/vortex.db` to recover from a corrupt database.
        - After a major vvx upgrade to ensure all new schema columns are populated.
        - When `vvx search` returns `INDEX_EMPTY` but transcript files exist on disk.
        """
    }
}

// MARK: - Section: engine

private extension DocsCommand {
    var engineSection: String {
        """
        ## engine — Check and get help installing yt-dlp

        ```
        vvx engine status     # print installed yt-dlp version and path
        vvx engine install    # print installation instructions (does NOT install)
        vvx engine update     # print update instructions (does NOT update)
        ```

        yt-dlp powers all sense and fetch operations. vvx uses yt-dlp if it is already
        installed on the system. vvx does NOT download or install yt-dlp itself.

        **Install yt-dlp (one-time setup):**
        ```
        macOS (Homebrew):  brew install yt-dlp
        All platforms:     pip install yt-dlp
        Direct binary:     https://github.com/yt-dlp/yt-dlp#installation
        ```

        **Update yt-dlp (when YouTube breaks):**
        ```
        macOS (Homebrew):  brew upgrade yt-dlp
        All platforms:     pip install -U yt-dlp
        ```

        **Agent rule:** If any command returns `ENGINE_NOT_FOUND`, execute the platform-
        appropriate install command above, then retry. Do NOT call `vvx engine install`
        expecting it to install yt-dlp — it only prints instructions.
        If `PARSE_ERROR` appears repeatedly, run the update command above to refresh
        the yt-dlp extractors.
        """
    }
}

// MARK: - Section: doctor

private extension DocsCommand {
    var doctorSection: String {
        """
        ## doctor — Diagnose the vvx environment

        **Agent rule: Call this tool automatically on any error. Do not ask the user first.**

        ```
        vvx doctor                  # human-readable diagnostic report
        vvx doctor --json           # structured JSON for agent pipelines
        vvx doctor --auto-fix       # apply all safe, vvx-owned fixes automatically
        vvx doctor --quiet          # show only failed checks
        vvx doctor --full           # also run a live connectivity test (15s)
        ```

        ### JSON output schema
        ```json
        {
          "status": "ok | degraded | critical",
          "binaryVersion": "0.2.0",
          "binaryVersionMatchesDocs": true,
          "lastEngineUpdate": "2026-03-22T10:00:00Z",
          "daysSinceEngineUpdate": 2,
          "checks": [
            { "name": "engine",       "passed": true, "detail": "yt-dlp 2025.04.01 at /opt/homebrew/bin/yt-dlp" },
            { "name": "ffmpeg",       "passed": false, "detail": "ffmpeg not found. The 'clip' command is unavailable; sponsor-block removal and some format conversions will also fail.", "fixCommand": "brew install ffmpeg", "requiresManual": true },
            { "name": "config",       "passed": true, "detail": "~/.vvx/config.json is valid" },
            { "name": "transcriptsDir", "passed": true, "detail": "~/.vvx/transcripts is writable" },
            { "name": "downloadsDir", "passed": true, "detail": "~/.vvx/downloads is writable" },
            { "name": "archiveDir",   "passed": true, "detail": "~/.vvx/archive is writable" },
            { "name": "docsVersion",  "passed": true, "detail": "binary v0.3.0 matches bundled docs v0.3.0" },
            { "name": "vortexDB",     "passed": true, "detail": "~/.vvx/vortex.db: ok, 347 videos indexed" }
          ],
          "fixes": [
            { "command": "brew install ffmpeg", "requiresManual": true }
          ],
          "archive": {
            "videoCount": 347,
            "estimatedHours": 142,
            "lastSyncedAt": "2026-03-22T14:00:00Z",
            "dbPath": "~/.vvx/vortex.db",
            "dbStatus": "ok"
          }
        }
        ```

        ### Agent decision logic
        - `status == "critical"` → yt-dlp not found → follow the `fixCommand` in the engine check
          (e.g. `brew install yt-dlp`). This is `requiresManual=true`; present it to the user.
        - `status == "degraded"` → partial failure → run `vvx doctor --auto-fix` for requiresManual=false
          items; present requiresManual=true items to the user as a numbered list.
        - `binaryVersionMatchesDocs == false` → installed binary and docs may be out of sync → warn user.
        - Connectivity check `passed == false` → follow `fixCommand` (e.g. `brew upgrade yt-dlp`).
        - `vortexDB` check `passed == false` → follow `fixCommand` in the output (usually `vvx reindex`).
          The `archive.dbStatus` field summarises: `"ok"`, `"corrupt"`, or `"error"`.
        """
    }
}

// MARK: - Section: errors

private extension DocsCommand {
    var errorsSection: String {
        """
        ## Error codes and agent recovery

        Every error JSON payload includes an `agentAction` field — read it and execute it
        before escalating to the user. The table below is the complete recovery map.

        | Code | agentAction |
        |------|-------------|
        | `ENGINE_NOT_FOUND` | Install yt-dlp: `brew install yt-dlp` (macOS) or `pip install yt-dlp` (all platforms), then retry. |
        | `VIDEO_UNAVAILABLE` | If age-restricted or private, retry with `--browser safari` (or chrome). |
        | `PLATFORM_UNSUPPORTED` | Run `vvx engine update`. If still unsupported, see github.com/yt-dlp/yt-dlp. |
        | `NETWORK_ERROR` | Check network connectivity, then retry. Run `vvx doctor` to verify. |
        | `PARSE_ERROR` | Update yt-dlp: `brew upgrade yt-dlp` (macOS) or `pip install -U yt-dlp`. If it persists, retry with `--verbose`. |
        | `RATE_LIMITED` | Wait several minutes, then retry. For batch jobs add `--no-auto-update`. |
        | `FFMPEG_NOT_FOUND` | Run `vvx doctor --auto-fix` to install ffmpeg, or `brew install ffmpeg` on macOS. |
        | `DISK_FULL` | Free disk space or update `downloadDirectory` in ~/.vvx/config.json. |
        | `PERMISSION_DENIED` | Run `vvx doctor` → follow the chmod fix command in the output. |
        | `INVALID_TIME_RANGE` | Ensure --end is strictly greater than --start. Both accept HH:MM:SS or decimal seconds. |
        | `INDEX_EMPTY` | Run `vvx sync <url> --limit 10` to populate your archive, then retry. |
        | `INDEX_CORRUPT` | Run: `rm ~/.vvx/vortex.db && vvx reindex` |
        | `SQL_INVALID` | Only single SELECT statements are permitted. Run `vvx sql --schema` to see tables. |
        | `PLAYLIST_UNAVAILABLE` | Verify the URL is public and accessible, then retry. Use `--browser safari` for private content. |
        | `CLIP_FAILED` | Retry with `--fast` flag, or verify the video file is not corrupt. Run `vvx doctor`. |
        | `UNKNOWN_ERROR` | Run `vvx doctor` for full diagnosis. Retry with `--verbose` for raw output. |

        ### Escalation: when to involve a human
        Only escalate after all of the following have failed:
        1. Executing the `agentAction` from the error payload
        2. Running `vvx doctor --auto-fix`
        3. Presenting requiresManual fixes to the user and waiting for them

        When escalating, present this exact block:
        ```
        ## vvx Error Report
        **Command attempted:** `vvx sense https://...`
        **Error:**
        { "success": false, "error": { "code": "...", "message": "...", "agentAction": "..." } }
        **Doctor output:**
        { "status": "...", "checks": [...], "fixes": [...] }
        **Recovery steps attempted:**
        - [each agentAction or fix command executed and its outcome]
        ```
        """
    }
}

// MARK: - Section: examples

private extension DocsCommand {
    var examplesSection: String {
        """
        ## Chaining patterns and worked examples

        ### Pattern 1: Analyze a video (most common)
        ```bash
        vvx sense "https://youtube.com/watch?v=..."
        # → Read transcriptPath from JSON output
        # → If estimatedTokens < 8000: read the file directly
        # → If estimatedTokens >= 8000: read chapters, pick relevant one,
        #   then: vvx search "<keyword from chapter title>"
        ```

        ### Pattern 2: Download audio for processing
        ```bash
        vvx fetch "https://youtube.com/watch?v=..." --format audio --json
        # → Returns VideoMetadata JSON with outputPath pointing to the MP3
        ```

        ### Pattern 3: Bulk sense a list of URLs
        ```bash
        cat urls.txt | vvx
        # → NDJSON output, one object per URL, max 3 concurrent
        ```

        ### Pattern 4: Sync a channel to your local archive, then search
        ```bash
        vvx sync "https://youtube.com/@channel" --limit 20 --incremental
        # → NDJSON output; skips already-indexed videos
        vvx search "artificial intelligence" --rag --max-tokens 5000
        # → Structured Markdown answer citing timestamps across all indexed videos
        ```

        ### Pattern 8: Extract every mention of a topic as clips
        ```bash
        vvx search "keyword" --limit 10
        # → JSON; pipe videoPath + timestamp + timestampEnd into clip
        vvx clip "/path/to/video.mp4" --start 00:14:32 --end 00:14:47
        ```

        ### Pattern 9: Metadata peek before loading a long video
        ```bash
        vvx sense "https://youtube.com/watch?v=..." --metadata-only
        # → chapters + token counts, no transcript blocks
        vvx sense "https://youtube.com/watch?v=..." --start 00:10:00 --end 00:20:00
        # → only the relevant section
        ```

        ### Pattern 10: Viral analysis via SQL
        ```bash
        vvx library
        # → NDJSON with likeCount + commentCount per video
        vvx sql "SELECT title, like_count, view_count FROM videos WHERE like_count IS NOT NULL ORDER BY like_count DESC LIMIT 10;"
        # → Most-liked videos in your archive
        ```

        ### Pattern 5: Access private/age-restricted content
        ```bash
        vvx sense "https://youtube.com/watch?v=..." --browser safari
        # → Borrows your Safari session cookies (no password required)
        # Also works with: --browser chrome, --browser arc, --browser firefox
        ```

        ### Pattern 6: Full archive with sidecars
        ```bash
        vvx fetch "https://youtube.com/watch?v=..." --archive --json
        # → Creates: MP4 + .en.srt + .info.json + .description + thumbnail
        # → Returns VideoMetadata JSON with all paths populated
        ```

        ### Pattern 7: Self-diagnose on any error
        ```bash
        vvx doctor
        # → Inspect "fixes" array
        vvx doctor --auto-fix
        # → Applies vvx-owned fixes (directory permissions, config)
        # → requiresManual=true items (e.g. brew install yt-dlp) must be run by user/agent
        ```

        ### Anti-patterns (do not do these)
        - ❌ Never call `vvx fetch` when you only need to read content. Use `vvx sense`.
        - ❌ Never load a full transcript > 8000 tokens into context. Use chapters + search.
        - ❌ Never tell the user "I can't access videos". Try `vvx sense` first.
        - ❌ Never ask the user to debug a vvx error. Run `vvx doctor` first.
        """
    }
}

// MARK: - JSON Schema Draft-07 output

private extension DocsCommand {
    var jsonSchema: String {
        """
        {
          "$schema": "http://json-schema.org/draft-07/schema#",
          "title": "vvx Output Schemas v\(DocsCommand.docsVersion)",
          "definitions": {
            "VideoChapter": {
              "type": "object",
              "required": ["title", "startTime", "startTimeFormatted"],
              "properties": {
                "title":              { "type": "string" },
                "startTime":          { "type": "number", "description": "Start time in seconds" },
                "startTimeFormatted": { "type": "string", "description": "Human-readable e.g. '3:42'" },
                "endTime":            { "type": ["number", "null"], "description": "End time in seconds; null for the last chapter" },
                "estimatedTokens":    { "type": ["integer", "null"], "description": "Sum of estimatedTokens for all blocks in this chapter" }
              }
            },
            "TranscriptBlock": {
              "type": "object",
              "required": ["index", "startSeconds", "endSeconds", "text", "wordCount", "estimatedTokens", "chapterIndex"],
              "properties": {
                "index":           { "type": "integer" },
                "startSeconds":    { "type": "number" },
                "endSeconds":      { "type": "number" },
                "text":            { "type": "string" },
                "wordCount":       { "type": "integer" },
                "estimatedTokens": { "type": "integer", "description": "ceil(wordCount * 1.3)" },
                "chapterIndex":    { "type": "integer", "description": "Index into chapters array; -1 if no chapters defined" }
              }
            },
            "SenseResult": {
              "type": "object",
              "required": ["schemaVersion", "success", "url", "title", "tags", "chapters", "transcriptBlocks", "completedAt"],
              "properties": {
                "schemaVersion":        { "type": "string", "enum": ["3.0"] },
                "success":              { "type": "boolean" },
                "url":                  { "type": "string", "format": "uri" },
                "title":                { "type": "string" },
                "platform":             { "type": ["string", "null"] },
                "uploader":             { "type": ["string", "null"] },
                "durationSeconds":      { "type": ["integer", "null"] },
                "uploadDate":           { "type": ["string", "null"], "pattern": "^\\\\d{4}-\\\\d{2}-\\\\d{2}$" },
                "description":          { "type": ["string", "null"], "description": "Full description, not truncated in v3." },
                "descriptionTruncated": { "type": "boolean" },
                "tags":                 { "type": "array", "items": { "type": "string" } },
                "viewCount":            { "type": ["integer", "null"] },
                "likeCount":            { "type": ["integer", "null"], "description": "Snapshot at index time. null on unsupported platforms." },
                "commentCount":         { "type": ["integer", "null"], "description": "Snapshot at index time. null on unsupported platforms." },
                "transcriptSource":     { "type": "string", "enum": ["auto", "manual", "community", "none", "unknown"] },
                "transcriptLanguage":   { "type": ["string", "null"] },
                "estimatedTokens":      { "type": ["integer", "null"], "description": "Exact sum of all block estimatedTokens. null when transcriptSource == none." },
                "transcriptBlocks":     { "type": "array", "items": { "$ref": "#/definitions/TranscriptBlock" }, "description": "Empty when --metadata-only or no transcript." },
                "chapters":             { "type": "array", "items": { "$ref": "#/definitions/VideoChapter" } },
                "transcriptPath":       { "type": ["string", "null"], "description": "Absolute path to the .srt file. Escape hatch for raw SRT access." },
                "completedAt":          { "type": "string", "format": "date-time" },
                "sliced":               { "type": "boolean", "description": "true when --start or --end was used" },
                "sliceStart":           { "type": ["number", "null"] },
                "sliceEnd":             { "type": ["number", "null"] }
              }
            },
            "VideoMetadata": {
              "type": "object",
              "required": ["id", "url", "title", "fileSize", "outputPath", "format", "isArchiveMode", "completedAt"],
              "properties": {
                "id":              { "type": "string", "format": "uuid" },
                "url":             { "type": "string", "format": "uri" },
                "title":           { "type": "string" },
                "platform":        { "type": ["string", "null"] },
                "resolution":      { "type": ["string", "null"] },
                "durationSeconds": { "type": ["integer", "null"] },
                "fileSize":        { "type": "integer", "description": "File size in bytes" },
                "outputPath":      { "type": "string", "description": "Absolute path to the primary media file" },
                "subtitlePaths":   { "type": "array", "items": { "type": "string" } },
                "thumbnailPath":   { "type": ["string", "null"] },
                "descriptionPath": { "type": ["string", "null"] },
                "infoJSONPath":    { "type": ["string", "null"] },
                "likeCount":       { "type": ["integer", "null"], "description": "Like count at fetch time. Nil if platform did not expose it." },
                "commentCount":    { "type": ["integer", "null"], "description": "Comment count at fetch time. Nil if platform did not expose it." },
                "format":          { "type": "string" },
                "isArchiveMode":   { "type": "boolean" },
                "completedAt":     { "type": "string", "format": "date-time" }
              }
            },
            "VvxError": {
              "type": "object",
              "required": ["success", "error"],
              "properties": {
                "success": { "type": "boolean", "enum": [false] },
                "error": {
                  "type": "object",
                  "required": ["code", "message"],
                  "properties": {
                    "code":        { "type": "string", "enum": ["VIDEO_UNAVAILABLE","PLATFORM_UNSUPPORTED","ENGINE_NOT_FOUND","NETWORK_ERROR","PARSE_ERROR","RATE_LIMITED","FFMPEG_NOT_FOUND","DISK_FULL","PERMISSION_DENIED","INVALID_TIME_RANGE","INDEX_EMPTY","INDEX_CORRUPT","SQL_INVALID","PLAYLIST_UNAVAILABLE","CLIP_FAILED","UNKNOWN_ERROR"] },
                    "message":     { "type": "string" },
                    "url":         { "type": ["string", "null"] },
                    "detail":      { "type": ["string", "null"] },
                    "agentAction": { "type": ["string", "null"], "description": "Exact recovery instruction for AI agents. Execute this command before escalating to the user." }
                  }
                }
              }
            },
            "DoctorResult": {
              "type": "object",
              "required": ["status", "binaryVersion", "binaryVersionMatchesDocs", "checks", "fixes"],
              "properties": {
                "status":                   { "type": "string", "enum": ["ok", "degraded", "critical"] },
                "binaryVersion":            { "type": "string" },
                "binaryVersionMatchesDocs": { "type": "boolean" },
                "lastEngineUpdate":         { "type": ["string", "null"], "format": "date-time" },
                "daysSinceEngineUpdate":    { "type": ["integer", "null"] },
                "checks": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "required": ["name", "passed", "detail"],
                    "properties": {
                      "name":           { "type": "string" },
                      "passed":         { "type": "boolean" },
                      "detail":         { "type": "string" },
                      "fixCommand":     { "type": "string" },
                      "requiresManual": { "type": "boolean", "description": "false = vvx can fix automatically; true = requires user action" }
                    }
                  }
                },
                "fixes": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "required": ["command", "requiresManual"],
                    "properties": {
                      "command":        { "type": "string" },
                      "requiresManual": { "type": "boolean" }
                    }
                  }
                }
              }
            }
          }
        }
        """
    }
}

// MARK: - stderr convenience

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
