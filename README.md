# VideoVortex Core (`vvx`)

**The high-performance local media extraction engine and Digital Asset Manager for AI agents and professional editors.**

`vvx` is a local-first, headless CLI that turns chaotic visual media into structured, LLM-ready context. It indexes video transcripts and metadata into a lightning-fast SQLite database (FTS5), enabling sub-second search and frame-accurate timeline assembly for modern NLEs (Premiere Pro, Final Cut, Resolve) — all on your local silicon.

## ⚡ Core Philosophy

- **Local-First & Private:** Runs entirely on your machine. No API costs, no cloud latency, 100% private.
- **Agent-Native:** Outputs strict JSON/NDJSON to stdout. Designed from the ground up to be orchestrated by MCP servers, Cursor, Aider, and OpenClaw.
- **The Editor's Bridge:** From transcript search to frame-accurate MP4 segments in seconds — batch `gather` (Pro) for many hits, or `clip` for a single file. Or skip extraction entirely and export a ready-to-cut NLE timeline with zero re-encode.
- **Engine-Agnostic:** `vvx` acts as a neutral orchestrator, utilizing standard system-level dependencies (`yt-dlp`, `ffmpeg`) to process media URLs and local files.

---

## 🛠 Prerequisites & Installation

`vvx` relies on system-level dependencies to process media and extract clips. Install them once via your package manager before running `vvx`.

### 1. Install Dependencies

**Metadata engine** (required for URL ingestion: `sense`, `fetch`, `sync`):

```bash
brew install yt-dlp          # macOS with Homebrew (recommended)
pip install yt-dlp           # macOS / Linux / Windows
```

**Media tooling** (required for `clip`, `gather`, format conversion):

```bash
brew install ffmpeg          # macOS with Homebrew
apt-get install -y ffmpeg    # Debian / Ubuntu
```

### 2. Install vvx

```bash
brew install videovortex-app/tap/vvx
```

### 3. Verify Environment

```bash
vvx doctor
```

---

## 🚀 The 3-Step "Wow" Workflow

Index a channel, search for a topic, and batch-extract matching `.mp4` clips for your editor.

```bash
# 1. Ingest a channel's metadata and transcripts into the local SQLite vault
vvx sync "https://youtube.com/@channel" --limit 20 --incremental --archive

# 2. Search the database for an exact quote or topic
vvx search "artificial intelligence" --rag

# 3. Batch-extract frame-accurate clips from search hits (Pro; optional output dir)
vvx gather "artificial intelligence" --limit 5 -o ~/Desktop/vvx-clips
```

Use `vvx gather --help` for all flags. Use `vvx doctor` whenever any command fails.

---

## 📖 Core CLI Commands

| Command | Purpose |
|--------|---------|
| `vvx sense <url>` | Extract structured metadata + transcript JSON (no media download by default). |
| `vvx sync <url>` | Bulk ingest channel/playlist data into the local `vortex.db`. |
| `vvx fetch <url>` | Fetch a single video and its sidecars into the vault. |
| `vvx search "query"` | Sub-second FTS5 search — keyword, structural, proximity, chapter, or NLE export. |
| `vvx gather "query"` | Batch-extract search hits as MP4 clips with sidecars into an output folder. **(Pro)** |
| `vvx clip <videoPath>` | Extract an exact MP4 segment from a local media file (`--start` / `--end`). |
| `vvx ingest <path>` | Index a local folder of video files into `vortex.db` — no download, no file movement. |
| `vvx library` | List archived/indexed videos in your local vault. |
| `vvx reindex` | Rebuild / backfill index data from on-disk archives. |
| `vvx sql "SELECT ..."` | Read-only analytics queries against local `vortex.db`. |
| `vvx doctor` | Validate the environment and surface missing `$PATH` dependencies. |
| `vvx docs` | Full LLM-optimized command documentation, schemas, and error reference. |

*Note: `vvx <url>` with no subcommand defaults to `sense`.*

### Repository & binaries

| Piece | Role |
|--------|------|
| **VideoVortexCore** | Shared Swift library (indexing, download orchestration, engine integration). |
| **vvx** | Main CLI. |
| **vvx-mcp** | MCP server for Cursor / Claude Desktop. |
| **vvx-serve** | Local HTTP API (`vvx serve --port …`). |

**Build from source:** `git clone https://github.com/videovortex-app/vvx.git && cd vvx && swift build -c release` — binaries under `.build/release/`. Linux builds need `libsqlite3-dev` and a SQLite module map (see project Docker/testing notes if applicable).

---

## 🔍 `vvx search` — five modes

`search` is the central hub. The same command covers five distinct workflows:

### 1. Keyword search (default)

```bash
vvx search "artificial general intelligence"
vvx search "AI AND danger" --uploader "Lex Fridman"
vvx search "mars colonization" --platform YouTube --after 2024-01-01 --limit 20
vvx search "neuralink" --rag                     # agent-optimized Markdown + clip commands
vvx search "AGI" --rag --max-tokens 5000
```

### 2. NLE export — zero re-encode timeline assembly **(Pro)**

Writes a ready-to-import project file referencing your archive files in-place. No re-encode, no extra disk usage, sub-second generation.

```bash
vvx search "neuralink" --export-nle fcpx     --export-nle-out ~/Desktop/cuts.fcpxml
vvx search "neuralink" --export-nle premiere --export-nle-out ~/Desktop/cuts.xml
vvx search "neuralink" --export-nle resolve  --export-nle-out ~/Desktop/cuts.edl
vvx search "AGI"       --export-nle fcpx     --export-nle-out ~/Desktop/agi.fcpxml --dry-run
```

Supported formats: `fcpx` (Final Cut Pro 10.4.1+), `premiere` (XMEML v4), `resolve` (CMX 3600 EDL).

Optional flags: `--pad <seconds>` (handle size, default 2.0), `--frame-rate <fps>` (EDL/Premiere timebase, default 29.97), `--context-seconds <N>`, `--snap off|block|chapter`, `--dry-run`.

### 3. Structural search — no query required

Find the best segments by *structure*, not keywords.

```bash
# Longest unbroken monologues (great for talking-head clips)
vvx search --uploader "Lex Fridman" --longest-monologue --limit 5
vvx search --after 2025-01-01 --longest-monologue --monologue-gap 3.0

# Highest words-per-second density (great for rapid-fire highlight reels)
vvx search --platform YouTube --high-density --limit 10
vvx search --uploader "Joe Rogan" --high-density --density-window 30 --limit 5
```

Results include `transcriptExcerpt` (up to 1,000 chars) and `structuralScore` — ready for LLM evaluation in a two-step pipeline.

### 4. Proximity search

Find the exact moment two or more concepts collide within a time window. Uses explicit `AND` — not the same as a boolean query.

```bash
vvx search "AGI AND security" --within 30
vvx search "Tesla AND autopilot" --within 45 --uploader "Lex Fridman"
vvx search "neuralink AND FDA" --within 60 --after 2024-01-01 --limit 10
```

Results sorted by `proximitySpanSeconds` ascending (tightest collision first).

### 5. Chapter search

Search chapter titles directly, one result per matching chapter.

```bash
vvx search "AGI safety" --chapters-only
vvx search "nuclear energy" --chapters-only --uploader "Lex Fridman" --limit 10
```

**Mutual-exclusion rules:** `--export-nle` cannot be combined with `--longest-monologue`, `--high-density`, or `--within`. `--within` requires explicit `AND` in the query. `--chapters-only` is mutually exclusive with `--longest-monologue`, `--high-density`, `--rag`, and `--export-nle`.

---

## 📦 `vvx gather` — batch clip extraction **(Pro)**

Extracts every search hit as a frame-accurate MP4 with re-timed `.srt` sidecars, `manifest.json`, and `clips.md` into an organized output folder.

### Output folder layout

```
Gather_artificial_intelligence_20260330_143052/
├── 01_Lex_Fridman_14m32s_artificial_general.mp4
├── 01_Lex_Fridman_14m32s_artificial_general.srt   # re-timed to clip timeline
├── 02_Joe_Rogan_00h45m10s_danger_of_agi.mp4
├── 02_Joe_Rogan_00h45m10s_danger_of_agi.srt
├── manifest.json                                   # machine-readable, all metadata
└── clips.md                                        # human-readable index
```

### Key flags

| Flag | Default | Purpose |
|------|---------|---------|
| `--limit <N>` | 20 | Max clips to extract. |
| `-o <path>` / `--output` | `~/Desktop/Gather_<query>_<timestamp>/` | Output directory. |
| `--context-seconds <N>` | 1.0 | Editorial breathing room before/after cue. |
| `--snap off\|block\|chapter` | `off` | Cue+context / exact cue / full chapter span. |
| `--pad <N>` | 2.0 | NLE handle seconds before/after logical in/out (clamp ≥ 0). |
| `--max-total-duration <N>` | — | Hard cap on total clip duration; drops lower-relevance clips first. |
| `--dry-run` | false | Plan only — no ffmpeg, no directory creation. |
| `--fast` | false | Keyframe seek + stream copy (instant, ±2–5s drift). |
| `--exact` | false | Re-encode with libx264 CRF 18 for frame-accurate handles. Mutually exclusive with `--fast`. |
| `--thumbnails` | false | Extract one JPEG still per clip at logical clip start. |
| `--open` | false | Open output folder in Finder/Files after completion. |
| `--embed-source` | false | Embed source URL + title + uploader into MP4 metadata atoms. |
| `--chapters-only` | false | Extract full creator-defined chapter segments matching the query. |
| `--uploader <name>` | — | Filter by channel/uploader. |
| `--platform <name>` | — | Filter by platform (YouTube, TikTok, …). |
| `--after <YYYY-MM-DD>` | — | Only videos uploaded on or after this date. |
| `--min-views <N>` | — | Engagement filter; applied in SQL before `--limit`. |
| `--min-likes <N>` | — | Engagement filter; applied in SQL before `--limit`. |
| `--min-comments <N>` | — | Engagement filter; applied in SQL before `--limit`. |

### Examples

```bash
vvx gather "artificial general intelligence" --limit 10
vvx gather "AI AND danger" --uploader "Lex Fridman" --context-seconds 2
vvx gather "Tesla" --min-views 1000000 --min-likes 50000 --dry-run
vvx gather "AGI" --snap chapter --limit 5
vvx gather "AGI safety" --chapters-only --limit 3 --pad 0
vvx gather "news" --max-total-duration 600
vvx gather "neuralink" --thumbnails --open --embed-source
```

### NDJSON output contract

Every clip outcome is one line on stdout. Agents branch on `success` and `error.code`:

- **Success:** `{"success":true,"outputPath":"…","videoId":"…","startTime":"…","endTime":"…","durationSeconds":…,"resolvedStartSeconds":…,"resolvedEndSeconds":…,"padSeconds":…,"paddedStartSeconds":…,"paddedEndSeconds":…,"encodeMode":"copy|default|exact","snapApplied":"off|block|chapter","method":"…","sizeBytes":…, …}`
- **Clip failure:** `{"success":false,"error":{"code":"CLIP_FAILED","message":"…","agentAction":"…"},"videoId":"…", …}`
- **Skipped (no local file):** `{"success":false,"error":{"code":"VIDEO_UNAVAILABLE","message":"…","agentAction":"vvx fetch \"<url>\" --archive"},"videoId":"…", …}`
- **Budget skip:** `{"success":false,"skipped":true,"reason":"budget_exceeded","videoId":"…","plannedDurationSeconds":…}`
- **Final summary line:** `{"success":true,"summary":true,"succeeded":N,"failed":N,"total":N,"dryRun":false,"outputDir":"…","manifestPath":"…|null"}`

**Exit codes:** `0` = all succeeded (or zero hits, or `--dry-run`). `1` = any clip failed.

---

## 📂 `vvx ingest` — index local media files

Points `vvx` at any local folder. Finds video files, matches sibling `.srt` / `.info.json` sidecars, and indexes into `vortex.db` using absolute paths — **without moving, copying, or modifying your files**.

```bash
vvx ingest /Volumes/Projects/InterviewRushes
vvx ingest ./rushes --dry-run
vvx ingest /path/to/folder --force-reindex
vvx ingest ~/Downloads --extensions mp4,mov,mkv
```

| Flag | Default | Purpose |
|------|---------|---------|
| `--dry-run` | false | Walk + match sidecars, no DB writes or ffprobe. |
| `--force-reindex` | false | Re-upsert metadata for paths already in the DB. |
| `--extensions <list>` | `mp4` | Comma-separated extension allowlist. |
| `--verbose` | false | Print additional skip detail to stderr. |

**Output (stdout, NDJSON):** One line per indexed/skipped file, then a final `{"type":"summary","indexed":N,"skipped":N,"skipped_reasons":{"non_video":N,"invalid_sidecar":N,"corrupt_media":N,"already_indexed":N},"malformed_info_json_count":N}`.

**Stderr:** Progress heartbeat every ~100 files. Prefix `DRY-RUN: ` when `--dry-run` is active.

---

## 🤖 MCP Server Setup (Claude Desktop / Cursor)

`vvx` includes `vvx-mcp`, a native Model Context Protocol server that gives AI agents direct access to your local video archive.

Add the following to your `~/Library/Application Support/Claude/claude_desktop_config.json` (Claude Desktop) or your Cursor MCP config:

```json
{
  "mcpServers": {
    "videovortex": {
      "command": "vvx-mcp",
      "args": []
    }
  }
}
```

Once configured, the agent discovers all tools automatically.

### MCP Tool Reference

| Tool | Purpose | Required fields |
|------|---------|-----------------|
| `sense` | Metadata + transcript (SenseResult v3) | `url` |
| `fetch` | Ingest video to archive | `url` |
| `search` | FTS5 / structural / proximity / chapter search | `query` (optional for structural), `outputFormat` |
| `gather` | Batch clip extraction with sidecars **(Pro)** | `query` |
| `sync` | Bulk channel/playlist ingest | `url`, `limit` |
| `clip` | Extract MP4 segment from local file | `inputPath`, `start`, `end` |
| `ingest` | Index a local folder into vortex.db | `path` |
| `library` | List indexed/archived videos | — |
| `sql` | Read-only analytics against vortex.db | `query` |
| `reindex` | Rebuild transcript_blocks + chapter_index | — |
| `doctor` | Diagnose environment & dependencies | — |

**Agent notes:**
- `search.outputFormat` is required for keyword mode — use `"rag"` for Markdown with clip commands, or `"json"` for structured chaining.
- Keep `sync.limit` small (5–20) to stay within MCP client timeouts.
- `gather` returns a `GatherSummaryLine` as the final NDJSON line; read `manifestPath` from it for downstream use.
- `ingest` supports optional `dryRun` (bool) and `forceReindex` (bool) — prefer `dryRun: true` on unknown trees.

---

## ⚖️ Free vs Pro

| Tier | Commands |
|------|---------|
| **Free** | `sense`, `fetch`, `sync`, `search`, `clip`, `ingest`, `library`, `sql`, `reindex`, `doctor`, `docs` |
| **Pro** | `gather`, `search --export-nle` |

Until billing is live, all features are accessible (beta/fail-open policy). Run `vvx doctor` to confirm your environment.

---

## 🔗 Stable API surface for tooling and GUI consumers

Phase 3.5 ships the following stable contracts that downstream tooling (local GUI, scripts, agents) may rely on:

- **`manifest.json` `schemaVersion: 2`** — written by every `vvx gather` run. Fields: `query`, `outputDir`, `encodeMode`, `padSeconds`, `clips[]` (each with `outputPath`, `srtPath`, `logicalStartSeconds`, `logicalEndSeconds`, `paddedStartSeconds`, `paddedEndSeconds`, `reproduceCommand`, `encodeMode`, `transcriptSource`, engagement snapshot, chapter info). `schemaVersion` will increment on breaking field changes.
- **`GatherSummaryLine` (final stdout NDJSON line)** — `outputDir` + `manifestPath` are the handoff artifacts. Tools should read `manifestPath` from the last line rather than reconstructing the path.
- **`vvx search` NDJSON** — `videoPath`, `startSeconds`, `endSeconds`, `reproduceCommand` are stable for chaining into `clip` or `gather`.
- **`vvx ingest` summary** — `skipped_reasons` keys (`non_video`, `invalid_sidecar`, `corrupt_media`, `already_indexed`) and `malformed_info_json_count` are always present and stable.

---

## ⚖️ License

Distributed under the Apache 2.0 License. See [LICENSE](LICENSE) for more information.

*VideoVortex is a registered trademark of VideoVortex Inc. macOS, Final Cut Pro, and Premiere Pro are trademarks of their respective owners.*
