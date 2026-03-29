import Foundation

// MARK: - ClipWindowResolver

/// Pure, side-effect-free clip window resolution and budget capping.
///
/// All methods are `static` and return data only — no `print`, no `fputs`,
/// no `stderr`. Warnings are returned as `[String]` for the caller to emit.
///
/// Used by `vvx gather` and `vvx search --export-nle` (Step 6) so both
/// commands produce mathematically identical clip boundaries.
public struct ClipWindowResolver {

    // Throttle cap: emit at most this many individual chapter-snap notes
    // before collapsing the rest into a single summary line.
    private static let snapNoteMax = 5

    // MARK: - Window resolution

    /// Resolves a clip window for every search hit.
    ///
    /// - Parameters:
    ///   - hits:           FTS search results to resolve.
    ///   - snapMode:       Alignment mode (`.off`, `.block`, `.chapter`).
    ///   - contextSeconds: Seconds added before/after cue in `.off` mode.
    /// - Returns: A tuple of resolved clips (in the same order as `hits`,
    ///   minus any skipped invalids) and human-readable warning strings for
    ///   the caller to print.
    public static func resolveWindows(
        hits: [SearchHit],
        snapMode: SnapMode,
        contextSeconds: Double
    ) -> (clips: [ResolvedClip], warnings: [String]) {

        var clips: [ResolvedClip] = []
        var warnings: [String]    = []
        var snapNoteCount = 0

        for hit in hits {
            let cueStart    = hit.startSeconds
            let cueEnd      = GatherPathNaming.parseSRTTimestampToSeconds(hit.endTime)
                ?? (hit.startSeconds + 10)
            let durationMax = hit.videoDurationSeconds.map { Double($0) }
                ?? Double.greatestFiniteMagnitude

            switch snapMode {

            case .off:
                let start = max(0, cueStart - contextSeconds)
                let end   = min(durationMax, cueEnd + contextSeconds)
                guard end > start else {
                    warnings.append("⚠ Skipping hit at \(hit.startTime) (invalid resolved window after context).")
                    continue
                }
                clips.append(ResolvedClip(
                    hit:                  hit,
                    resolvedStartSeconds: start,
                    resolvedEndSeconds:   end,
                    snapApplied:          .off,
                    cueStartSeconds:      cueStart,
                    cueEndSeconds:        cueEnd,
                    snapNote:             nil
                ))

            case .block:
                let start = cueStart
                let end   = min(durationMax, cueEnd)
                guard end > start else {
                    warnings.append("⚠ Skipping hit at \(hit.startTime) (zero-width cue block).")
                    continue
                }
                clips.append(ResolvedClip(
                    hit:                  hit,
                    resolvedStartSeconds: start,
                    resolvedEndSeconds:   end,
                    snapApplied:          .block,
                    cueStartSeconds:      cueStart,
                    cueEndSeconds:        cueEnd,
                    snapNote:             nil
                ))

            case .chapter:
                guard let idx = hit.chapterIndex,
                      !hit.chapters.isEmpty,
                      idx >= 0,
                      idx < hit.chapters.count else {
                    // Chapter metadata missing — fall back to block bounds.
                    warnings.append(
                        "--snap chapter: missing chapter_index for hit at \(hit.startTime) " +
                        "(\(hit.videoId)); using cue bounds (run vvx reindex for chapters)."
                    )
                    let start = cueStart
                    let end   = min(durationMax, cueEnd)
                    clips.append(ResolvedClip(
                        hit:                  hit,
                        resolvedStartSeconds: start,
                        resolvedEndSeconds:   end,
                        snapApplied:          .block,
                        cueStartSeconds:      cueStart,
                        cueEndSeconds:        cueEnd,
                        snapNote:             nil
                    ))
                    continue
                }

                let ch     = hit.chapters[idx]
                let start  = max(0, ch.startTime)
                let rawEnd: Double
                if let chEnd = ch.endTime {
                    rawEnd = chEnd
                } else if let dur = hit.videoDurationSeconds {
                    rawEnd = Double(dur)
                } else {
                    rawEnd = durationMax
                }
                let end = min(durationMax, rawEnd)

                guard end > start else {
                    // Degenerate chapter bounds — fall back to block.
                    warnings.append(
                        "--snap chapter: degenerate chapter bounds for \"\(ch.title)\"; using cue bounds."
                    )
                    clips.append(ResolvedClip(
                        hit:                  hit,
                        resolvedStartSeconds: cueStart,
                        resolvedEndSeconds:   min(durationMax, cueEnd),
                        snapApplied:          .block,
                        cueStartSeconds:      cueStart,
                        cueEndSeconds:        cueEnd,
                        snapNote:             nil
                    ))
                    continue
                }

                // Throttled chapter-shift note: emit only when window shifted > 0.1 s.
                let shifted = abs(start - cueStart) > 0.1 || abs(end - cueEnd) > 0.1
                let note: String? = shifted ? ch.title : nil
                if shifted && snapNoteCount < snapNoteMax {
                    let startFmt = TimeParser.formatHHMMSS(start)
                    let endFmt   = TimeParser.formatHHMMSS(end)
                    let cueSFmt  = TimeParser.formatHHMMSS(cueStart)
                    let cueEFmt  = TimeParser.formatHHMMSS(cueEnd)
                    warnings.append(
                        "Snap: cue \(cueSFmt)–\(cueEFmt) → chapter \"\(ch.title)\" \(startFmt)–\(endFmt)"
                    )
                    snapNoteCount += 1
                    if snapNoteCount == snapNoteMax {
                        warnings.append("… and more chapter snap(s) (omitted; same --snap chapter behavior).")
                    }
                }

                clips.append(ResolvedClip(
                    hit:                  hit,
                    resolvedStartSeconds: start,
                    resolvedEndSeconds:   end,
                    snapApplied:          .chapter,
                    cueStartSeconds:      cueStart,
                    cueEndSeconds:        cueEnd,
                    snapNote:             note
                ))
            }
        }

        return (clips, warnings)
    }

    // MARK: - Budget cap

    /// Partitions `clippable` into clips that fit within `maxTotalDuration`
    /// and those that must be skipped.
    ///
    /// When `maxTotalDuration` is `nil`, all clips are included.
    /// Inclusion order follows FTS relevance order (front of array first).
    ///
    /// - Parameters:
    ///   - clippable:         Clips eligible for extraction (local file present).
    ///   - maxTotalDuration:  Hard cap on the sum of `plannedDuration`, in seconds.
    /// - Returns: `(include, skip)` partitions.
    public static func applyBudgetCap(
        _ clippable: [ResolvedClip],
        maxTotalDuration: Double?
    ) -> (include: [ResolvedClip], skip: [ResolvedClip]) {
        guard let cap = maxTotalDuration else {
            return (clippable, [])
        }
        var accumulated = 0.0
        var include: [ResolvedClip] = []
        var skip: [ResolvedClip]    = []

        for rc in clippable {
            if skip.isEmpty && accumulated + rc.plannedDuration <= cap {
                accumulated += rc.plannedDuration
                include.append(rc)
            } else {
                skip.append(rc)
            }
        }
        return (include, skip)
    }
}
