# VideoVortex Core (`vvx`)

**The high-performance local media extraction engine and Digital Asset Manager for AI agents and professional editors.**

`vvx` is a local-first, headless CLI that turns chaotic visual media into structured, LLM-ready context. It indexes video transcripts and metadata into a lightning-fast SQLite database (FTS5), enabling sub-second search and frame-accurate timeline assembly for modern NLEs (Premiere Pro, Final Cut, Resolve) — all on your local silicon.

## ⚡ Core Philosophy

- **Local-First & Private:** Runs entirely on your machine. No API costs, no cloud latency, 100% private.
- **Agent-Native:** Outputs strict JSON/NDJSON to stdout. Designed from the ground up to be orchestrated by MCP servers, Cursor, Aider, and OpenClaw.
- **The Editor's Bridge:** Move from transcript search to frame-accurate MP4 segments—batch `gather` (Pro) for many hits, or `clip` for a single local file—ready to drop into Premiere, Final Cut, or Resolve.
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

Use `vvx gather --help` for filters (`--uploader`, engagement thresholds, `--fast`, `--dry-run`).

---

## 📖 Core CLI Commands

| Command | Purpose |
|--------|---------|
| `vvx sense <url>` | Extract structured metadata + transcript JSON (no media download by default). |
| `vvx sync <url>` | Bulk ingest channel/playlist data into the local `vortex.db`. |
| `vvx search "query"` | Sub-second FTS5 search across indexed transcript blocks. |
| `vvx gather "query"` | Batch-extract search hits as MP4 clips into an output folder (Pro). |
| `vvx clip <videoPath>` | Extract an exact MP4 segment from a local media file (`--start` / `--end`). |
| `vvx library` | List archived/indexed videos in your local vault. |
| `vvx reindex` | Rebuild / backfill index data from on-disk archives. |
| `vvx sql "SELECT ..."` | Read-only analytics queries against local `vortex.db`. |
| `vvx fetch <url>` | Fetch a single video and its sidecars into the vault. |
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
| `search` | FTS5 transcript search | `query`, `outputFormat` |
| `sync` | Bulk channel/playlist ingest | `url`, `limit` |
| `clip` | Extract MP4 segment from local file | `inputPath`, `start`, `end` |
| `library` | List indexed/archived videos | — |
| `sql` | Read-only analytics against vortex.db | `query` |
| `reindex` | Rebuild transcript_blocks + chapter_index | — |
| `doctor` | Diagnose environment & dependencies | — |

*Agent note: `search.outputFormat` is required — use `"rag"` for Markdown with clip commands, or `"json"` for structured chaining. Keep `sync.limit` small (5–20) to stay within MCP client timeouts.*

---

## ⚖️ License

Distributed under the Apache 2.0 License. See [LICENSE](LICENSE) for more information.

*VideoVortex is a registered trademark of VideoVortex Inc. macOS, Final Cut Pro, and Premiere Pro are trademarks of their respective owners.*
