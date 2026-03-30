import Foundation

// MARK: - SnapMode

/// Window-alignment mode for clip extraction.
///
/// Shared by `vvx gather` and `vvx search --export-nle` so both produce
/// mathematically identical clip boundaries.
///
/// - `off`:     Cue bounds ± `contextSeconds` (start clamped ≥ 0).
/// - `block`:   Exact cue bounds; `contextSeconds` is ignored.
/// - `chapter`: Full chapter span containing the hit; `contextSeconds` is ignored.
///              Falls back to `.block` when chapter metadata is absent.
///
/// `ExpressibleByArgument` conformance is added via extension in the `vvx`
/// CLI target to avoid pulling ArgumentParser into VideoVortexCore.
public enum SnapMode: String, CaseIterable, Sendable {
    case off
    case block
    case chapter
}

// MARK: - ResolvedClip

/// A resolved clip window, computed once per search hit.
///
/// Carries the final logical start/end used by ffmpeg, dry-run, NDJSON output,
/// and NLE timeline export. Pad handles (`--pad`) are applied on top of these
/// values by `FFmpegRunner.paddedBounds` — they are not embedded here.
public struct ResolvedClip: Sendable {

    /// The originating FTS search hit.
    public let hit: SearchHit

    /// Final logical start, in seconds, after snap/context resolution.
    public let resolvedStartSeconds: Double

    /// Final logical end, in seconds, after snap/context resolution.
    public let resolvedEndSeconds: Double

    /// The snap mode actually applied (may differ from the requested mode
    /// when a chapter-snap fallback occurred).
    public let snapApplied: SnapMode

    /// Original FTS cue start in seconds — used for budget accounting and
    /// delta reporting in stderr.
    public let cueStartSeconds: Double

    /// Original FTS cue end in seconds — used for budget accounting and
    /// delta reporting in stderr.
    public let cueEndSeconds: Double

    /// Human-readable note populated when chapter snap meaningfully shifts the
    /// window (e.g. the chapter title). `nil` when no notable shift occurred.
    public let snapNote: String?

    /// Logical clip duration before pad handles are added.
    public var plannedDuration: Double { resolvedEndSeconds - resolvedStartSeconds }

    public init(
        hit: SearchHit,
        resolvedStartSeconds: Double,
        resolvedEndSeconds: Double,
        snapApplied: SnapMode,
        cueStartSeconds: Double,
        cueEndSeconds: Double,
        snapNote: String?
    ) {
        self.hit                  = hit
        self.resolvedStartSeconds = resolvedStartSeconds
        self.resolvedEndSeconds   = resolvedEndSeconds
        self.snapApplied          = snapApplied
        self.cueStartSeconds      = cueStartSeconds
        self.cueEndSeconds        = cueEndSeconds
        self.snapNote             = snapNote
    }
}
