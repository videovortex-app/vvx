import Foundation

// MARK: - ProximityHit

/// A single FTS5 hit belonging to one specific search term.
///
/// Used as input to `ProximityAnalyzer.minimumWindow(termHits:withinSeconds:blocks:)`.
public struct ProximityHit: Sendable {
    /// The AND-split term this hit belongs to (e.g. "AGI").
    public let term:         String
    public let startSeconds: Double
    public let endSeconds:   Double
    /// Matched block text.
    public let text:         String

    public init(term: String, startSeconds: Double, endSeconds: Double, text: String) {
        self.term         = term
        self.startSeconds = startSeconds
        self.endSeconds   = endSeconds
        self.text         = text
    }
}

// MARK: - ProximityWindow

/// The tightest temporal window containing at least one hit from every required term.
///
/// Returned by `ProximityAnalyzer.minimumWindow(termHits:withinSeconds:blocks:)`.
public struct ProximityWindow: Sendable {
    /// `startSeconds` of the earliest term hit in this window.
    public let startSeconds:         Double
    /// `endSeconds` of the latest term hit in this window.
    public let endSeconds:           Double
    /// `latestHit.startSeconds − earliestHit.startSeconds`.
    /// Primary sort key: ascending (tightest collision first).
    public let proximitySpanSeconds: Double
    /// One representative hit per required term — the last (rightmost) occurrence of
    /// each term within the window, giving the tightest representation.
    public let termHits:             [ProximityHit]
    /// Full text of all transcript blocks spanning [startSeconds, endSeconds],
    /// truncated at 1,000 characters. Ready for LLM evaluation in Phase 3.6.
    public let transcriptExcerpt:    String
}

// MARK: - ProximityAnalyzer

/// Deterministic proximity collision detection — no LLM, no network, no I/O.
///
/// Uses an O(n) minimum-window sweep (classic "smallest window containing all required
/// elements") adapted for temporal (seconds-based) coordinates.  `n` is the total number
/// of FTS5 hits across all terms.
public enum ProximityAnalyzer {

    // MARK: - minimumWindow

    /// Find the tightest window containing at least one hit from every required term.
    ///
    /// Uses an O(n) minimum-window sweep over all hits merged and sorted by `startSeconds`.
    /// Returns `nil` when:
    /// - `withinSeconds` ≤ 0
    /// - fewer than 2 required terms (proximity is undefined for a single term)
    /// - any term has an empty hit array
    /// - no window within `withinSeconds` exists
    ///
    /// - Parameters:
    ///   - termHits: Dict mapping each required term to its FTS5 hit array (from per-term
    ///     DB queries).  All hit arrays must be ordered by `startSeconds` ascending.
    ///   - withinSeconds: Maximum allowed span.  Windows exceeding this are discarded.
    ///   - blocks: All transcript blocks for this video (ordered by `startSeconds`).
    ///     Used to extract the `transcriptExcerpt` from the surrounding text.
    /// - Returns: The single tightest `ProximityWindow`, or `nil` if none qualifies.
    public static func minimumWindow(
        termHits:      [String: [ProximityHit]],
        withinSeconds: Double,
        blocks:        [StoredBlock]
    ) -> ProximityWindow? {
        guard withinSeconds > 0 else { return nil }
        guard termHits.count >= 2 else { return nil }
        guard termHits.values.allSatisfy({ !$0.isEmpty }) else { return nil }

        // 1. Merge all per-term hits into one flat array sorted by startSeconds.
        let allHits: [(term: String, hit: ProximityHit)] = termHits
            .flatMap { term, hits in hits.map { (term: term, hit: $0) } }
            .sorted { $0.hit.startSeconds < $1.hit.startSeconds }

        let required = Set(termHits.keys)
        var termCount = [String: Int]()
        var covered   = 0
        var left      = 0
        var best: ProximityWindow?

        // 2. Advance right pointer; shrink left when all terms are covered.
        for right in 0 ..< allHits.count {
            let rTerm = allHits[right].term
            if termCount[rTerm, default: 0] == 0 { covered += 1 }
            termCount[rTerm, default: 0] += 1

            while covered == required.count {
                let span = allHits[right].hit.startSeconds - allHits[left].hit.startSeconds
                if span <= withinSeconds {
                    if best == nil || span < best!.proximitySpanSeconds {
                        best = ProximityWindow(
                            startSeconds:         allHits[left].hit.startSeconds,
                            endSeconds:           allHits[right].hit.endSeconds,
                            proximitySpanSeconds: span,
                            termHits:             collectRepHits(
                                                      allHits[left ... right],
                                                      required
                                                  ),
                            transcriptExcerpt:    excerptFromBlocks(
                                                      blocks,
                                                      from:     allHits[left].hit.startSeconds,
                                                      to:       allHits[right].hit.endSeconds,
                                                      maxChars: 1000
                                                  )
                        )
                    }
                }
                // Shrink from left.
                let lTerm = allHits[left].term
                termCount[lTerm]! -= 1
                if termCount[lTerm]! == 0 { covered -= 1 }
                left += 1
            }
        }
        return best
    }

    // MARK: - Private helpers

    /// For each required term, returns the last (rightmost by `startSeconds`) hit within
    /// `slice`. Using the rightmost occurrence keeps each rep hit as tight as possible
    /// to the window boundary.
    static func collectRepHits(
        _ slice:    ArraySlice<(term: String, hit: ProximityHit)>,
        _ required: Set<String>
    ) -> [ProximityHit] {
        var repByTerm = [String: ProximityHit]()
        for tagged in slice {
            repByTerm[tagged.term] = tagged.hit   // later entries overwrite — picks rightmost
        }
        return required.compactMap { repByTerm[$0] }
    }

    /// Filter `blocks` within ±0.5 s of `[from, to]`, join `.text`, truncate at `maxChars`.
    static func excerptFromBlocks(
        _ blocks:  [StoredBlock],
        from:      Double,
        to:        Double,
        maxChars:  Int
    ) -> String {
        let buffer = 0.5
        let filtered = blocks.filter {
            $0.startSeconds >= from - buffer && $0.startSeconds <= to + buffer
        }
        let joined = filtered.map(\.text).joined(separator: " ")
        return String(joined.prefix(maxChars))
    }
}
