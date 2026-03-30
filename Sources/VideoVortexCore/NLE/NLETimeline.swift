import Foundation

// MARK: - NleExportFormat

/// Supported NLE timeline export formats.
///
/// `ExpressibleByArgument` conformance is added in the `vvx` CLI target via extension
/// to avoid pulling ArgumentParser into VideoVortexCore.
public enum NleExportFormat: String, CaseIterable, Sendable {
    case fcpx   // FCPXML 1.9 — Final Cut Pro 10.4.1+
    // Step 7: case premiere, case resolve
}

// MARK: - NLETimeline

/// Format-agnostic timeline model consumed by NLE writers (FCPXMLWriter, etc.).
///
/// Assembled by the CLI layer from `[ResolvedClip]` + padded bounds.
/// Contains only what writers need — no gather-specific fields.
public struct NLETimeline: Sendable {

    /// Query string used as the FCP project name and event label.
    public let title: String

    public let generatedAt: Date

    /// Frame rate for the FCPXML sequence format ruler (default 29.97).
    /// Affects only the timeline ruler in FCP — clip trim accuracy is not dependent on this.
    public let frameRate: Double

    public let clips: [NLEClip]

    public init(
        title: String,
        generatedAt: Date = Date(),
        frameRate: Double = 29.97,
        clips: [NLEClip]
    ) {
        self.title       = title
        self.generatedAt = generatedAt
        self.frameRate   = frameRate
        self.clips       = clips
    }
}

// MARK: - NLEClip

/// A single clip entry in an NLE timeline.
public struct NLEClip: Sendable {

    /// Zero-padded sequence index: "01", "02", … (width = max(2, digit count of total)).
    public let id: String

    /// Canonical URL (videos.id from vortex.db). Used to derive the stable UID.
    public let sourceUrl: String

    /// Absolute, tilde-expanded local file path. Used as the FCPXML asset src.
    public let sourcePath: String

    /// Source video duration in seconds from vortex.db. `nil` when unavailable —
    /// the FCPXML asset duration will be written as "0s" and FCP re-reads it on import.
    public let sourceDurationSeconds: Double?

    public let title: String
    public let uploader: String?

    /// Source in-point: `max(0, resolvedStart − pad)`.
    public let inSeconds: Double

    /// Source out-point: `resolvedEnd + pad` (clamped to `sourceDuration` when known).
    public let outSeconds: Double

    /// Matched cue text (first ≤200 chars). Used as the FCPXML clip name suffix and `<note>`.
    public let matchedText: String

    /// Chapter title when the hit has chapter metadata. Written as a `<marker>` in FCPXML.
    public let chapterTitle: String?

    /// Equivalent `vvx clip …` shell command to reproduce this exact clip window.
    public let reproduceCommand: String

    public init(
        id: String,
        sourceUrl: String,
        sourcePath: String,
        sourceDurationSeconds: Double?,
        title: String,
        uploader: String?,
        inSeconds: Double,
        outSeconds: Double,
        matchedText: String,
        chapterTitle: String?,
        reproduceCommand: String
    ) {
        self.id                    = id
        self.sourceUrl             = sourceUrl
        self.sourcePath            = sourcePath
        self.sourceDurationSeconds = sourceDurationSeconds
        self.title                 = title
        self.uploader              = uploader
        self.inSeconds             = inSeconds
        self.outSeconds            = outSeconds
        self.matchedText           = matchedText
        self.chapterTitle          = chapterTitle
        self.reproduceCommand      = reproduceCommand
    }

    /// Clip duration in the NLE timeline: `outSeconds − inSeconds`.
    public var duration: Double { outSeconds - inSeconds }
}
