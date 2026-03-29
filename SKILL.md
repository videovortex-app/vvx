# VideoVortex (vvx) — Agent Skill

**Version:** 0.3.0  
**Install:** `brew install videovortex-app/tap/vvx`  
**MCP:** Add `vvx-mcp` to `claude_desktop_config.json` (see Setup section)  
**What it does:** Turns any video URL into structured JSON + full transcripts, and provides sub-second search and NLE timeline assembly across your local media archive.

---

## Prerequisites (one-time setup)

vvx requires two external system dependencies to fetch and process media. Install them once before using any command.

**yt-dlp** (external metadata engine — required for `sense`, `fetch`, `sync`):

```bash
brew install yt-dlp          # macOS with Homebrew (recommended)
pip install yt-dlp           # macOS / Linux / Windows
```

**ffmpeg** (required for `clip`, `gather`, format conversion):

```bash
brew install ffmpeg          # macOS with Homebrew
apt-get install -y ffmpeg    # Debian / Ubuntu
```

After installing, run `vvx doctor` to confirm the environment is ready.

---

## When yt-dlp breaks (extractor errors)

Upstream platforms frequently change their formats, causing the external `yt-dlp` engine to fail with an extraction error. vvx will catch this and print:

> `yt-dlp failed with an extractor error. Update: brew upgrade yt-dlp`

Execute the system upgrade command and retry. vvx relies on your system package manager and does **not** update third-party binaries automatically.

```bash
brew upgrade yt-dlp          # macOS with Homebrew
pip install -U yt-dlp        # pip users
```

---

## When to Use This Skill

Use `vvx` when the user asks you to:

- Analyze, summarize, quote from, or answer questions about a video.
- Extract the full transcript of a video.
- Download media to disk (`fetch` / `sync`, or `dl` for a personal `~/Downloads` save).
- Search across a local video archive.
- Sync a channel or playlist into the local database.
- Batch-extract searched clips and assemble them for video editors (`gather`).

Do NOT use `vvx` for:

- Real-time streaming content (live streams not yet ended).
- Videos behind interactive login walls that browser cookies cannot reach.

---

## Quick Reference (for agents)

| What the user wants | Command to run |
|---|---|
| Analyze/summarize a video without downloading media | `vvx sense <url>` |
| Plan context usage first for long videos | `vvx sense <url> --metadata-only` |
| Fetch one video into library-style workflows | `vvx fetch <url>` |
| Fetch audio-only output | `vvx fetch <url> --format audio` |
| Sync channel/playlist into local archive | `vvx sync <url> --limit N [--incremental] [--archive]` |
| Search across indexed transcripts | `vvx search "query"` |
| Batch-extract search hits as raw video clips (Pro) | `vvx gather "query" --limit N [-o dir]` |
| Extract a video segment from a local file | `vvx clip <videoPath> --start <time> --end <time>` |
| Inspect archive inventory (downloaded media) | `vvx library --downloaded` |
| Run analytics safely against local DB | `vvx sql "SELECT ..."` *(OS-level read-only connection)* |
| Find most-liked/commented videos (engagement) | `vvx sql "SELECT title, like_count FROM videos ORDER BY like_count DESC LIMIT 10"` |
| Re-populate chapter assignments in DB | `vvx reindex` |
| Diagnose/fix environment issues | `vvx doctor` |
| Open full command documentation | `vvx docs` or `vvx docs <command>` |

---

## Critical Rules for Agents

1. **`transcriptBlocks` is the primary transcript interface (v3).**
   - Short videos: `transcriptBlocks` is inline in the JSON — use it directly.
   - Long videos: call `vvx sense <url> --metadata-only` first to get token counts and chapter structure without the block payload, then call again with `--start`/`--end` for specific sections, or use `vvx search` for keyword queries.

2. **Check `estimatedTokens` before loading the full block array.**
   - `estimatedTokens` = exact sum of all block tokens; use it for context-window planning.

3. **`transcriptSource == "none"` + empty `transcriptBlocks` = no usable transcript.** Stop.

4. **On any error, read the `agentAction` field first.** Execute it before escalating.

5. **If `agentAction` does not resolve the issue:**
   - Run `vvx doctor --json`
   - Apply all fixes where `requiresManual = false` automatically.
   - Execute package manager commands (e.g., `brew install`) for any missing dependencies.

6. **Never tell the user "I can't access videos."** Always try `vvx sense` first.

7. **Human file download only — `vvx dl`.** Use **only** when the user clearly asks to save a video file for personal viewing. `vvx dl <url>` bypasses `vortex.db`, emits no agent JSON, and writes a flat file under `~/Downloads`. For structured data, use `vvx sense` or `vvx fetch`.

---

## Output Schema (sense) — v3.0

```json
{
  "schemaVersion": "3.0",
  "success": true,
  "url": "string",
  "title": "string",
  "platform": "string | null",
  "uploader": "string | null",
  "durationSeconds": "integer | null",
  "uploadDate": "YYYY-MM-DD | null",
  "viewCount": "integer | null",
  "transcriptSource": "auto | manual | community | none | unknown",
  "estimatedTokens": "integer | null",
  "transcriptBlocks": [
    {
      "index": 1,
      "startSeconds": 0.0,
      "endSeconds": 3.5,
      "text": "Cleaned subtitle text.",
      "wordCount": 3,
      "estimatedTokens": 4,
      "chapterIndex": 0
    }
  ],
  "chapters": [
    {
      "title": "Intro",
      "startTime": 0.0,
      "endTime": 32.0,
      "estimatedTokens": 89
    }
  ],
  "transcriptPath": "/absolute/path/to/file.en.srt | null"
}
```

---

## Error Recovery Patterns

| Error Code | Immediate Action |
|------------|-----------------|
| `ENGINE_NOT_FOUND` | Install yt-dlp: `brew install yt-dlp` (macOS) or `pip install yt-dlp`, then retry |
| `VIDEO_UNAVAILABLE` | Retry with `--browser safari` |
| `PLATFORM_UNSUPPORTED` | Update yt-dlp: `brew upgrade yt-dlp` or `pip install -U yt-dlp`, then retry |
| `PARSE_ERROR` | Update yt-dlp: `brew upgrade yt-dlp` or `pip install -U yt-dlp`, then retry |
| `RATE_LIMITED` | Wait several minutes, then retry |
| `FFMPEG_NOT_FOUND` | Run `vvx doctor --auto-fix` to install ffmpeg, then retry |
| `NETWORK_ERROR` | Check connectivity, then retry. Run `vvx doctor`. |
| `INDEX_EMPTY` | Run `vvx sync <url> --limit 10` to populate archive, then retry |
| `INDEX_CORRUPT` | Run `rm ~/.vvx/vortex.db && vvx reindex` |
| `CLIP_FAILED` | Retry with `--fast`; verify file is not corrupt; run `vvx doctor` |
| Any other error | Run `vvx doctor` |

---

## MCP Setup (Claude Desktop / Cursor)

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (Claude Desktop) or your Cursor MCP config:

```json
{
  "mcpServers": {
    "videovortex": { "command": "vvx-mcp", "args": [] }
  }
}
```

Once configured, the agent discovers all tools automatically.

### Key MCP Transport Rules

- `tools/call` is a single blocking request/response. Batch tools (`sync`, `library`, `sql`, `reindex`) aggregate NDJSON lines in memory and return them as one text block.
- **`search.outputFormat`** — Must be `"json"` (structured, for chaining into `clip`) or `"rag"` (Markdown with clip commands, for answering user questions).
- **`sync.limit`** — Required. Prefer 5–20 videos per call to avoid MCP host timeouts.

---

## Decision Tree

```
User wants to analyze / summarize / quote from a video
  → vvx sense <url>   (check estimatedTokens first; use --metadata-only for long videos)

User wants to find a specific quote or topic across their archive
  → vvx search "query" --rag --max-tokens 5000

User wants to process all videos from a channel or playlist
  → vvx sync <url> --limit N [--incremental] [--archive]

User wants batch clips from search hits for editing
  → vvx gather "query" --limit N [-o output-dir] [--fast]

User wants to see what videos are in their archive
  → vvx library   (or vvx library --downloaded for media files only)

User wants metadata analytics (top uploaders, upload dates, engagement)
  → vvx sql "SELECT ..."  (like_count / comment_count available from Phase 3)

User wants to find viral / highly-liked videos in their archive
  → vvx sql "SELECT title, like_count, view_count FROM videos WHERE like_count IS NOT NULL ORDER BY like_count DESC LIMIT 10;"
```

---

## Agent Workflow Recipes

```bash
# Recipe 1: Metadata-first planning for long videos
vvx sense "<url>" --metadata-only
vvx sense "<url>" --start 00:10:00 --end 00:15:00

# Recipe 2: Channel ingest → search → gather
vvx sync "https://youtube.com/@channel" --incremental --limit 20
vvx search "topic" --rag --max-tokens 5000
vvx gather "keyword" --limit 10 -o ~/Desktop/gather-clips

# Recipe 3: Archive inventory and analytics
vvx library
vvx sql "SELECT uploader, COUNT(*) AS videos FROM videos GROUP BY uploader ORDER BY videos DESC LIMIT 10;"
```
