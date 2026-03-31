# vvx — Agent Reference Manual
**Version:** 0.2.0
**Written for:** AI agents. Tone: precise, no marketing.
**What it does:** Turns any video URL into structured JSON + full transcript
without downloading the media file.

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
vvx sense <url> --transcript-dir ~/Desktop/srts   # override transcript output location
vvx sense <url> --timeout 120                    # yt-dlp/network timeout in seconds
vvx sense <url> --all-subs                       # download all available subtitle tracks
vvx sense <url> --no-auto-update                 # deprecated no-op; retained for compatibility
vvx sense <url> --no-sponsors                    # strip SponsorBlock segments (requires ffmpeg)
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

## fetch — Download video file to local archive

Use fetch when the user explicitly wants a file on disk.
Do not use fetch when the user just wants to read or analyze a video — use sense instead.

### Usage
```
vvx fetch <url>
vvx fetch <url> --archive             # full project folder: MP4 + SRT + .info.json + thumbnail
vvx fetch <url> --format audio        # MP3 extract only
vvx fetch <url> --format broll        # video-only, no audio track
vvx fetch <url> --format 1080         # cap resolution at 1080p
vvx fetch <url> --format 720          # cap resolution at 720p
vvx fetch <url> --browser safari      # access private/age-restricted content
vvx fetch <url> --output-dir ~/Desktop/downloads  # override output directory
vvx fetch <url> --all-subs             # download all available subtitle tracks
vvx fetch <url> --no-auto-update       # deprecated no-op; retained for compatibility
vvx fetch <url> --no-sponsors         # strip SponsorBlock segments (requires ffmpeg)
vvx fetch <url> --json                # print VideoMetadata JSON to stdout on completion
vvx fetch url1 url2 url3              # multiple URLs, NDJSON output
vvx fetch --batch urls.txt            # batch file (one URL per line), NDJSON output
cat urls.txt | vvx fetch              # stdin pipe, NDJSON output
```

### Formats
| Flag value | Result |
|------------|--------|
| `best` (default) | Best available quality MP4 |
| `1080` / `1080p` | Cap at 1080p |
| `720` / `720p` | Cap at 720p |
| `broll` | Video-only stream (no audio), for B-roll use |
| `audio` / `mp3` | MP3 audio extract |
| `reactionkit` | Side-by-side reaction layout (archive mode implied) |

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

## search — Full-text and structural search across indexed transcripts

Searches the FTS5 transcript index in `vortex.db`. Returns ranked hits with
surrounding context. Requires at least one video to be indexed first (via `sense`,
`fetch`, or `sync`).

Supports FTS5 query syntax: boolean operators (`AND`, `OR`, `NOT`), phrase search
(`"exact phrase"`), and prefix search (`intell*`). Porter stemming is active by
default — `"run"` matches `"running"`, `"AGI"` matches `"AGIs"`.

### Usage — keyword search
```
vvx search "query"
vvx search "query" --rag                        # structured Markdown for direct answer
vvx search "AI AND safety"                      # boolean AND — both terms must appear
vvx search "AGI OR robotics"                    # boolean OR — either term matches
vvx search "AI NOT politics"                    # boolean NOT — exclude term
vvx search "\"exact phrase\""                 # phrase search
vvx search "intell*"                            # prefix search
vvx search "query" --max-tokens 5000            # token-budget cap for --rag output
vvx search "query" --limit 20                   # max hits (default: 50)
vvx search "query" --platform YouTube           # filter by platform
vvx search "query" --after 2026-01-01           # filter by upload date
vvx search "query" --uploader "Channel Name"    # filter by uploader
vvx search "query" --frame-rate 29.97           # set NLE export timeline fps
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

### Structural search (no query required)

Deterministic transcript structure analysis — no LLM, no network, no cloud.
Operates on existing `transcript_blocks` data only. Free tier (no Pro gate).

#### `--longest-monologue`
Finds the single longest contiguous speech span per video, ranked by duration descending.
Two consecutive blocks are merged when the gap between them ≤ `--monologue-gap`.

```
vvx search --longest-monologue
vvx search --longest-monologue --uploader "Lex Fridman"
vvx search --longest-monologue --platform YouTube --limit 5
vvx search --longest-monologue --monologue-gap 3.0 --after 2025-01-01
```

| Flag | Default | Description |
|------|---------|-------------|
| `--monologue-gap <seconds>` | `1.5` | Max silence gap in seconds still counted as the same span. |

NDJSON output per result (one line per video):
```json
{
  "success": true,
  "mode": "longest_monologue",
  "rank": 1,
  "videoTitle": "Lex Fridman Podcast #400",
  "uploader": "Lex Fridman",
  "platform": "YouTube",
  "uploadDate": "2026-01-15",
  "videoPath": "/abs/path/to/video.mp4",
  "startSeconds": 1432.5,
  "endSeconds": 1874.0,
  "durationSeconds": 441.5,
  "blockCount": 87,
  "structuralScore": 441.5,
  "transcriptExcerpt": "...first ~1000 chars of span text...",
  "reproduceCommand": "vvx clip \"/abs/path/video.mp4\" --start 1432.5 --end 1874.0"
}
```
Final summary line:
```json
{"success":true,"mode":"longest_monologue","scannedVideos":42,"resultCount":5,"limit":5,"uploader":"Lex Fridman","platform":null,"afterDate":null}
```

#### `--high-density`
Finds the highest words-per-second window per video using a two-pointer sliding window.
Score = `wordCount / windowSeconds`. Ranked by `wordsPerSecond` descending.

```
vvx search --high-density
vvx search --high-density --density-window 30
vvx search --high-density --uploader "Joe Rogan" --limit 10
vvx search --high-density --platform YouTube --density-window 45 --after 2025-01-01
```

| Flag | Default | Description |
|------|---------|-------------|
| `--density-window <seconds>` | `60.0` | Sliding window width. Use `30` for tight highlight-reel clips. |

NDJSON output per result (one line per video):
```json
{
  "success": true,
  "mode": "high_density",
  "rank": 1,
  "videoTitle": "Joe Rogan Experience #2100",
  "uploader": "PowerfulJRE",
  "platform": "YouTube",
  "uploadDate": "2026-02-01",
  "videoPath": "/abs/path/to/video.mp4",
  "startSeconds": 3220.0,
  "endSeconds": 3280.0,
  "windowSeconds": 60.0,
  "wordCount": 412,
  "wordsPerSecond": 6.87,
  "structuralScore": 6.87,
  "transcriptExcerpt": "...first ~1000 chars of window text...",
  "reproduceCommand": "vvx clip \"/abs/path/video.mp4\" --start 3220.0 --end 3280.0"
}
```

Both structural modes now include chapter context on every result (when chapter data
is present on the video):
- `chapterTitle`: title of the chapter the span/window begins in (null if no chapters).
- `chapterIndex`: zero-based index into the video's chapters array.
- `isMultiChapter`: true when the span crosses a chapter boundary.

#### Structural search mutual-exclusion rules
- `--longest-monologue` and `--high-density` cannot be combined.
- Neither flag can be combined with a query string.
- Neither flag can be combined with `--export-nle`, `--within`, or `--chapters-only`.
- `--rag` cannot be used with structural flags.
- `--uploader`, `--platform`, `--after`, and `--limit` are compatible with both flags.

#### `structuralScore` field
A unified float for sorting/filtering in agent pipelines.
- `longest_monologue`: span duration in seconds (higher = longer).
- `high_density`: words per second (higher = denser).
- `proximity`: `proximitySpanSeconds` — **lower is better** (tighter collision).
  Results are pre-sorted correctly; agents do not need to re-sort.

### Chapter search (`--chapters-only`)

Search chapter titles instead of transcript text. Returns one result per chapter whose
title matches all query terms (case-insensitive AND semantics — all terms must match).

```
vvx search "AGI safety" --chapters-only
vvx search "nuclear energy" --chapters-only --uploader "Lex Fridman"
vvx search "mars" --chapters-only --platform YouTube --limit 10
vvx search "robotics" --chapters-only --after 2024-01-01
```

NDJSON output per result (one line per matching chapter):
```json
{
  "success": true,
  "mode": "chapters_only",
  "rank": 1,
  "videoId": "https://www.youtube.com/watch?v=xyz",
  "videoTitle": "Lex Fridman — Episode 400",
  "uploader": "Lex Fridman",
  "platform": "YouTube",
  "uploadDate": "2024-11-15",
  "videoPath": "/abs/path/to/video.mp4",
  "chapterTitle": "The AGI Debate",
  "chapterIndex": 3,
  "startSeconds": 4800.0,
  "endSeconds": 5760.0,
  "durationSeconds": 960.0,
  "transcriptExcerpt": "...first ~1000 chars of chapter transcript...",
  "reproduceCommand": "vvx clip \"/abs/path/video.mp4\" --start 4800.0 --end 5760.0"
}
```
Final summary line:
```json
{"success":true,"mode":"chapters_only","query":"AGI safety","terms":["AGI","safety"],"scannedVideos":47,"matchedChapters":8,"resultCount":5,"limit":5,"uploader":null,"platform":null,"afterDate":null}
```

#### `--chapters-only` mutual-exclusion rules
- Requires a query string.
- Cannot be combined with `--longest-monologue`, `--high-density`, `--rag`, `--export-nle`.
- `--uploader`, `--platform`, `--after`, and `--limit` are compatible.

Note: Chapter data requires that yt-dlp reported chapters when the video was fetched.
If no results appear, run `vvx library <videoId>` to inspect `chapters` or re-sense.

### Proximity search (explicit AND required)

Finds the tightest temporal collision between multiple concepts — sorted by
`proximitySpanSeconds` ascending (smallest window first). Plain boolean search tells
you both words appear somewhere in a 3-hour podcast; proximity tells you the exact
22-second moment they meet.

Requires a query with explicit `AND`. Space-separated terms (e.g. `"Lex Fridman"`)
run normal FTS — use `AND` to enable proximity.

```
vvx search "AGI AND security" --within 30
vvx search "Tesla AND autopilot" --within 45 --uploader "Lex Fridman"
vvx search "neuralink AND FDA" --within 60 --after 2024-01-01 --limit 10
```

| Flag | Description |
|------|-------------|
| `--within <seconds>` | Maximum proximity window in seconds. Must be > 0. |

NDJSON output per result (one line per video, sorted by tightest window first):
```json
{
  "success": true,
  "mode": "proximity",
  "rank": 1,
  "videoTitle": "Lex Fridman Podcast #400",
  "uploader": "Lex Fridman",
  "platform": "YouTube",
  "uploadDate": "2024-11-15",
  "videoPath": "/abs/path/to/video.mp4",
  "startSeconds": 1823.4,
  "endSeconds": 1847.9,
  "proximitySpanSeconds": 22.1,
  "withinSeconds": 30.0,
  "terms": ["AGI", "security"],
  "termHits": [
    { "term": "AGI", "startSeconds": 1823.4, "text": "the trajectory of AGI development..." },
    { "term": "security", "startSeconds": 1845.5, "text": "national security implications..." }
  ],
  "structuralScore": 22.1,
  "transcriptExcerpt": "...first ~1000 chars spanning the window...",
  "reproduceCommand": "vvx clip \"/abs/path/video.mp4\" --start 1823.4 --end 1847.9"
}
```
Final summary line:
```json
{"success":true,"mode":"proximity","terms":["AGI","security"],"withinSeconds":30.0,"candidateVideos":12,"resultCount":5,"limit":10,"uploader":null,"platform":null,"afterDate":null}
```

#### Proximity search mutual-exclusion rules
- `--within` requires a query with explicit `AND` (at least 2 terms).
- `--within` cannot be combined with `--longest-monologue` or `--high-density`.
- `--within` cannot be combined with `--export-nle`.
- `--within` without a query is a parse error.
- `--within 0` or negative values are parse errors.
- Single-term `AND` query (e.g. `"AGI"`) with `--within`: stderr note, falls through to standard FTS.

#### Why proximity beats FTS5 NEAR
FTS5 `NEAR` operates within a **single SRT block** (~3–5 s). If "AGI" ends block N
and "security" starts block N+1, `NEAR` misses the collision. The `--within` sweep
is the only mathematically sound tool for cross-block temporal proximity.

### Agent rules for search
- Use `--rag` when generating a user-facing answer from transcript content.
- Use JSON output when chaining into `clip` — extract `videoPath`, `timestamp`,
  and `timestampEnd` from each hit.
- Use `--longest-monologue` to find the best long-form rant or deep dive.
- Use `--high-density` to find the moment a speaker hammers a topic hardest.
- Use `--within` to find where two or more concepts collide in time — this is the
  goldilocks zone between phrase matching (too brittle) and boolean (too noisy).
- Use `--chapters-only` when the user asks about topics by chapter/section name —
  e.g. "find episodes with a chapter about AGI safety." Chapter search is faster
  than transcript FTS because it skips block loading entirely.
- For structural and proximity results, use `reproduceCommand` to cut the clip directly.
- `structuralScore` polarity differs by mode: higher is better for monologue/density,
  **lower is better for proximity** (tightest collision = smallest span).
- `INDEX_EMPTY` error means no videos are indexed yet: run `vvx sync <url> --limit 10`.
- For NLE export, source files must be on disk. Use `--dry-run` to check clip availability
  before writing the file.

## gather — Batch extract clips matching a search query (Pro)

Searches vortex.db for the query and extracts every matching transcript segment
as a frame-accurate MP4 clip into an organized output folder. Each clip comes with
re-timed SRT subtitles, a manifest.json, and a clips.md summary.

### Usage — standard gather
```
vvx gather "query" --limit 20
vvx gather "query" --uploader "Channel Name" --limit 10
vvx gather "query" --platform YouTube --after 2024-01-01
vvx gather "query" --snap chapter --limit 5        # clip full chapter spans
vvx gather "query" --min-views 1000000             # engagement filter
vvx gather "query" --dry-run                       # plan without extracting
vvx gather "query" --fast                          # keyframe seek (instant, ±5s)
vvx gather "query" --exact                         # re-encode for precision
vvx gather "query" --max-total-duration 600        # hard cap on total clip minutes
vvx gather "query" --pad 0                         # tight cuts, no handles
vvx gather "query" -o ~/Desktop/my-clips           # custom output directory
vvx gather "query" --output ~/Desktop/my-clips     # long-form output path flag
vvx gather "query" --open                          # reveal output folder when done
vvx gather "query" --thumbnails                    # write thumbnails for each clip
vvx gather "query" --embed-source                  # burn source metadata into outputs
vvx gather "query" --min-likes 10000               # engagement floor
vvx gather "query" --min-comments 500              # engagement floor
```

### Chapter-first gather (`--chapters-only`)

Search chapter titles instead of transcript text and extract each matching chapter
as a clip. `--snap chapter` is automatically implied — chapter boundaries are used
directly. `--context-seconds` is ignored. `--pad` applies normally.

```
vvx gather "AGI" --chapters-only
vvx gather "AI safety" --chapters-only --limit 3
vvx gather "robotics" --chapters-only --uploader "Lex Fridman" --pad 0
vvx gather "energy" --chapters-only --after 2024-01-01 --limit 5
```

Note: `--snap off` and `--snap block` cannot be combined with `--chapters-only`.
Using `--snap chapter` alongside `--chapters-only` is silently accepted.

Chapter data requires that yt-dlp reported chapters when the video was fetched.
If no results appear, run `vvx library <videoId>` to inspect `chapters` or re-sense.

### Clip window flags
| Flag | Default | Description |
|------|---------|-------------|
| `--context-seconds N` | `1.0` | Seconds before/after each cue. Ignored with `--snap block/chapter` and `--chapters-only`. |
| `--snap off` | default | Cue + context. |
| `--snap block` | | Exact cue bounds; ignores `--context-seconds`. |
| `--snap chapter` | | Full chapter span; ignores `--context-seconds`. Falls back to block if no chapter data. |
| `--pad N` | `2.0` | Handle seconds added by FFmpegRunner after snap/context resolution. |

### GatherClipSuccess NDJSON line
```json
{
  "success": true,
  "outputPath": "/path/to/001_uploader_0:14:32_snippet.mp4",
  "inputPath": "/path/to/source.mp4",
  "videoId": "https://youtube.com/watch?v=...",
  "title": "Video Title",
  "uploader": "Channel Name",
  "startTime": "00:14:32,000",
  "endTime": "00:14:47,000",
  "durationSeconds": 15.0,
  "resolvedStartSeconds": 872.0,
  "resolvedEndSeconds": 887.0,
  "padSeconds": 2.0,
  "paddedStartSeconds": 870.0,
  "paddedEndSeconds": 889.0,
  "plannedSrtPath": "/path/to/001_uploader_0:14:32_snippet.srt",
  "matchedText": "...transcript snippet...",
  "method": "frame_accurate",
  "sizeBytes": 4194304,
  "snapApplied": "off",
  "thumbnailPath": null,
  "embedSourceApplied": false,
  "embedSourceNote": null,
  "encodeMode": "default",
  "chapterTitle": "The AGI Debate",
  "chapterIndex": 3
}
```
`chapterTitle` and `chapterIndex` are null when the hit has no chapter data.
`snapApplied` is `"chapter"` for `--chapters-only` and `--snap chapter` results.

### Manifest files
Every gather run writes:
- `manifest.json` — machine-readable clip list with all timestamps and paths.
- `clips.md` — human-readable summary for sharing and review.

### Agent rules for gather
- Gather requires Pro entitlement and ffmpeg (`vvx doctor` to verify).
- Use `--dry-run` before large runs to verify clip counts and duration.
- Use `--chapters-only` when the user wants full topic segments rather than transcript hits.
- Use `--snap chapter` when the hit is inside a chapter and the user wants the full segment.
- `--pad 0` for tight editorial cuts; default `--pad 2` for NLE cross-dissolve handles.
- `FFMPEG_NOT_FOUND`: run `vvx doctor --auto-fix` to install ffmpeg, then retry.
- `VIDEO_UNAVAILABLE`: source not on disk — run `vvx fetch "<videoId>" --archive` first.

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
vvx sync <url> --limit 20 --all-subs            # download all available subtitle tracks
vvx sync <url> --limit 20 --no-auto-update      # deprecated no-op; retained for compatibility
vvx sync <url> --limit 20 --force               # re-sync videos even if already indexed
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

## clip — Extract a video segment as MP4

Cuts a precise segment from a local video file using ffmpeg. Requires ffmpeg
installed (run `vvx doctor` to verify).

### Usage
```
vvx clip <videoPath> --start HH:MM:SS --end HH:MM:SS
vvx clip <videoPath> --start HH:MM:SS --end HH:MM:SS --fast    # keyframe seek (±2-5s drift, instant)
vvx clip <videoPath> --start HH:MM:SS --end HH:MM:SS --exact   # re-encode (libx264 CRF 18, frame-accurate)
vvx clip <videoPath> --start HH:MM:SS --duration 15            # start + duration instead of end
vvx clip <videoPath> --start HH:MM:SS --end HH:MM:SS --pad 0   # no NLE handles (default: 2.0s)
vvx clip <videoPath> --start HH:MM:SS --end HH:MM:SS --output ~/Desktop/clip.mp4
vvx clip <videoPath> --start HH:MM:SS --end HH:MM:SS --open
vvx clip <videoPath> --start HH:MM:SS --end HH:MM:SS --thumbnails
vvx clip <videoPath> --start HH:MM:SS --end HH:MM:SS --embed-source
```

Time format: `HH:MM:SS`, `MM:SS`, decimal seconds (e.g. `872.5`), or compact (`1m30s`, `2h1m30s`).

### Output schema (JSON to stdout)
```json
{
  "success": true,
  "inputPath": "/absolute/path/to/source.mp4",
  "outputPath": "/absolute/path/to/clip_14m32s_to_14m47s.mp4",
  "startTime": "00:14:32",
  "endTime": "00:14:47",
  "durationSeconds": 15.0,
  "padSeconds": 2.0,
  "method": "frame_accurate",
  "encodeMode": "default",
  "embedSourceApplied": false,
  "sizeBytes": 4194304,
  "thumbnailPath": null,
  "completedAt": "2026-03-24T10:30:00Z"
}
```
`method` is `"frame_accurate"` (default), `"fast_copy"` (with `--fast`), or `"exact"` (with `--exact`).
`encodeMode` is `"default"`, `"copy"` (with `--fast`), or `"exact"` (with `--exact`).
`thumbnailPath` is populated when `--thumbnails` is passed. `--fast` and `--exact` are mutually exclusive.

### Agent rules for clip
- `FFMPEG_NOT_FOUND`: run `vvx doctor --auto-fix` to install ffmpeg, then retry.
- `CLIP_FAILED`: retry with `--fast`; if still failing the video file may be corrupt.
- Pair with `search` output: pass `videoPath`, `timestamp`, `timestampEnd` from a
  search hit directly into `clip`.

## ingest — Index a local folder of video files

Recursively scans a directory for video files, matches sibling sidecars (.srt,
.info.json), and indexes discovered media into vortex.db using absolute paths —
**without moving, copying, or modifying any user files**.

Use this when the user has existing footage on disk (NAS, external drive, project
folder, ~/Downloads) and wants to search it with `vvx search` or extract clips
with `vvx gather` without downloading anything through yt-dlp.

### Usage
```
vvx ingest <path>
vvx ingest <path> --dry-run           # walk + match, no DB writes or ffprobe
vvx ingest <path> --force-reindex     # re-upsert paths already in vortex.db
vvx ingest <path> --extensions mp4,mov,mkv   # extra video types (default: mp4)
vvx ingest <path> --verbose           # print skip details to stderr
```

Relative paths are resolved to absolute before any DB write.

### Sidecar matching
For `…/My Interview.mp4`, sidecars with the **same basename** in the same directory
are matched: `My Interview.srt`, `My Interview.en.srt`, `My Interview.info.json`.
Unrelated `.json` files in the folder are ignored.

### Deduplication
Files already in vortex.db by absolute path are skipped unless `--force-reindex`
is passed. This makes repeated `vvx ingest` safe on the same folder.

### stdout — NDJSON
One line per indexed/skipped file, then a final summary line:
```json
{"type":"summary","indexed":47,"skipped":12,"skipped_reasons":{"non_video":8,"invalid_sidecar":0,"corrupt_media":1,"already_indexed":3},"malformed_info_json_count":2}
```
All `skipped_reasons` keys are **always present** (value `0` if none). Agents must
check `skipped_reasons.already_indexed` to distinguish a no-op from a real error.

### stderr
Progress heartbeat every ~100 files: `Scanning… N files checked, M indexed.`
When `--dry-run` is active, prefix changes to: `DRY-RUN: Scanning… N files checked, M indexed.`

### Agent rules for ingest
- Always run `--dry-run` first on unknown or very large trees.
- Read `malformed_info_json_count` from the summary: non-zero means some `.info.json`
  files were unreadable but the run still succeeded (partial metadata only).
- After ingest completes, use `vvx search` or `vvx gather` as normal — indexed local
  files are treated identically to files downloaded via `vvx fetch --archive`.
- `PERMISSION_DENIED` on the root path → supply a valid, readable directory.
- Symlinks are not followed to prevent cycles.

## library — List all indexed/archived videos

Queries the `videos` table in `vortex.db` and returns NDJSON. Includes all
metadata fields including engagement counts captured at sense/fetch time.

### Usage
```
vvx library
vvx library --platform YouTube           # filter by platform
vvx library --uploader "Channel Name"    # filter by uploader
vvx library --downloaded                 # only videos with a local video file
vvx library --sort uploadDate            # explicit sort field
vvx library --paths-only                 # emit paths only for shell piping (implies --downloaded)
vvx library --json                       # NDJSON to stdout instead of human table
```

Default output is a human-readable table on **stderr**. Use `--json` for machine-readable NDJSON
on stdout (safe to pipe). `--paths-only` outputs one video path per line on stdout.

### Output schema (`--json` NDJSON — one object per line)
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
  "viewCount": 1482930,
  "likeCount": 48320,
  "commentCount": 3210
}
```

**Engagement fields** (`likeCount`, `commentCount`) are snapshots captured at
sense/fetch time. They are `null` for videos indexed before Phase 3, or on
platforms that do not expose the data. Use `vvx sql` to query them analytically.

## sql — Read-only analytics against vortex.db

Executes a single SELECT statement against the local SQLite database.
Only SELECT is permitted — mutations are rejected.

### Usage
```
vvx sql "SELECT ..."
vvx sql --schema                # print CREATE TABLE definitions for all tables
vvx sql "SELECT ..." --markdown # output results as a Markdown table (useful in --rag pipelines)
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

## reindex — Rebuild the transcript index from disk

Scans `~/.vvx/transcripts/` and `~/.vvx/archive/` for existing .srt files and
re-populates `vortex.db`. Use this after upgrading vvx or if the database is
missing or corrupt.

### Usage
```
vvx reindex
vvx reindex --dry-run    # preview without writing
vvx reindex --force      # re-import videos already indexed (refreshes metadata from .info.json)
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
| `PRO_REQUIRED` | `gather` and `search --export-nle` are Pro features. During beta all features are allowed (fail-open). If this code appears, inform the user to upgrade at https://videovortex.app |
| `NLE_NO_LOCAL_FILES` | Every search hit matched but no local archive file exists for any of them. Run `vvx fetch "<url>" --archive` for the missing source videos, then retry NLE export. |
| `NLE_WRITE_FAILED` | The NLE export file could not be written (permissions issue, disk full, or bad output path). Check the path and disk space, then retry. |
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

### Pattern 11: Batch clip extraction (gather)
```bash
# Dry-run first to see what would be extracted
vvx gather "artificial general intelligence" --limit 10 --dry-run
# → NDJSON planned clips + final summary line with outputDir

# Real run with sidecars and NLE handles
vvx gather "artificial general intelligence" --limit 10 --pad 2
# → MP4s + re-timed .srt + manifest.json + clips.md in Gather_<query>_<timestamp>/
# → Final line: {"success":true,"summary":true,"outputDir":"…","manifestPath":"…"}

# Chapter-first: extract full creator-defined segments
vvx gather "AI safety" --chapters-only --limit 5 --pad 0
```

### Pattern 12: NLE export — zero re-encode timeline (Pro)
```bash
# Dry-run to check available clips before writing the file
vvx search "neuralink" --export-nle fcpx --export-nle-out ~/Desktop/cuts.fcpxml --dry-run

# Write Final Cut Pro XML (drag into FCP — instant timeline, archive files referenced in-place)
vvx search "neuralink" --export-nle fcpx --export-nle-out ~/Desktop/cuts.fcpxml

# Premiere Pro
vvx search "neuralink" --export-nle premiere --export-nle-out ~/Desktop/cuts.xml

# DaVinci Resolve
vvx search "neuralink" --export-nle resolve --export-nle-out ~/Desktop/cuts.edl
```
If source files are missing, `NLE_NO_LOCAL_FILES` is returned.
Run `vvx fetch "<url>" --archive` for each missing video, then retry.

### Pattern 13: Two-step AI clip discovery
```bash
# Step 1 — find best structural candidates (no query needed)
vvx search --longest-monologue --uploader "Lex Fridman" --limit 10
# → Each result line has transcriptExcerpt (≤1000 chars) + reproduceCommand

# Step 1b — proximity: find the moment two topics collide
vvx search "AGI AND national security" --within 45 --limit 5

# Step 2 — agent evaluates transcriptExcerpt, then gathers approved clips
vvx gather "AGI" --snap chapter --limit 3 --pad 2
# → Or use reproduceCommand from step 1 results directly with `vvx clip`
```

### Pattern 14: Index local media folder
```bash
# Preview first on unfamiliar trees
vvx ingest /Volumes/Projects/InterviewRushes --dry-run
# → Final summary: indexed:0, skipped:…, skipped_reasons:{…}, dry_run:true (no writes)

# Real index run
vvx ingest /Volumes/Projects/InterviewRushes
# → Indexes all .mp4 files; matches sibling .srt + .info.json sidecars

# Then search and gather as normal
vvx search "product launch" --rag
vvx gather "product launch" --limit 5 -o ~/Desktop/launch-clips
```

### Anti-patterns (do not do these)
- ❌ Never call `vvx fetch` when you only need to read content. Use `vvx sense`.
- ❌ Never load a full transcript > 8000 tokens into context. Use chapters + search.
- ❌ Never tell the user "I can't access videos". Try `vvx sense` first.
- ❌ Never ask the user to debug a vvx error. Run `vvx doctor` first.
- ❌ Never pass `chaptersOnly` or `exportNle` to the MCP `search` tool — those are CLI-only.
- ❌ Never run `vvx gather` via MCP for > 5 clips without a dry-run preview first — MCP has timeouts.
