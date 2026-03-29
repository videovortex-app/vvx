# Phase 2.5: Linux Decontamination — Two-stage Docker build
#
# Stage 1 (builder): Compiles the vvx binary using the official Swift image.
# Stage 2 (runner):  Lean Swift runtime (noble-slim) with ffmpeg + latest yt-dlp via vvx engine install.
#
# Usage:
#   docker build -t vvx .
#   docker run --rm vvx sense "https://youtube.com/watch?v=..."
#
# NOTE: Do NOT `apt-get install yt-dlp` — the Ubuntu repo version is years out of date.
#       The Dockerfile uses `vvx engine install` to fetch the latest release from GitHub.

# ── Stage 1: Build ──────────────────────────────────────────────────────────────
FROM swift:6.2-noble AS builder

WORKDIR /build

# Cache dependency resolution separately from source compilation.
COPY Package.swift Package.resolved* ./
RUN swift package resolve

# Copy source and build the vvx CLI in release mode.
COPY Sources ./Sources
COPY Tests   ./Tests
RUN swift build -c release --product vvx 2>&1

# ── Stage 2: Runtime ────────────────────────────────────────────────────────────
# swift:6.2-noble-slim ships the Swift runtime libraries (libswiftCore.so, etc.)
# that the dynamically-linked vvx binary requires, without the full toolchain.
FROM swift:6.2-noble-slim

# Avoid interactive prompts during apt-get.
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies.
# ffmpeg:          used for thumbnail extraction and sponsor-block removal on Linux.
# ca-certificates: needed for HTTPS connections (GitHub API, video platforms).
# python3/curl omitted — vvx engine install fetches the standalone yt-dlp binary
# from GitHub via URLSession; the Python runtime is not required.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy the compiled vvx binary from the builder stage.
COPY --from=builder /build/.build/release/vvx /usr/local/bin/vvx

# Smoke test — fails fast here if Swift runtime libraries are still missing.
# --help is an ArgumentParser built-in that always exits 0; vvx has no --version flag.
RUN /usr/local/bin/vvx --help

# Install the latest yt-dlp from GitHub via vvx's own engine installer.
# This validates that `vvx engine install` works end-to-end on Linux,
# and ensures the container has a current yt-dlp (not an outdated apt package).
RUN /usr/local/bin/vvx engine install

ENTRYPOINT ["/usr/local/bin/vvx"]
