import Foundation

// MARK: - ResolveEDLWriter

/// Pure CMX 3600 EDL generator for DaVinci Resolve.
///
/// - No file I/O: `write(_:)` returns `Data`; the caller writes to disk.
/// - No console output: all errors are thrown.
/// - No ffmpeg: references existing archive files by filename in `* SOURCE FILE:` comments.
/// - One event per `NLEClip`; contiguous record timeline (no gaps).
/// - Timecodes: NDF SMPTE `HH:MM:SS:FF` via `TimecodeFormatter.ndfTimecode(_:fps:)`.
/// - Reel: `AX` (Auxiliary Tape) for all events — file-based relinking via `* SOURCE FILE:`.
/// - Metadata comments per event:
///   - `* SOURCE FILE: {filename}` — Resolve uses this for media relinking.
///   - `* FROM CLIP NAME: {id}. {uploader|title} — {snippet}` — populates clip name.
///   - `* LOC: {REC_IN} RED {chapterTitle}` — creates a red timeline marker (when present).
public enum ResolveEDLWriter {

    // MARK: - Errors

    public enum ResolveEDLError: Error {
        case encodingFailed
    }

    // MARK: - Public entry point

    /// Encodes `timeline` as a UTF-8 CMX 3600 EDL.
    public static func write(_ timeline: NLETimeline) throws -> Data {
        let edl = buildEDL(timeline)
        guard let data = edl.data(using: .utf8) else {
            throw ResolveEDLError.encodingFailed
        }
        return data
    }

    // MARK: - EDL builder

    private static func buildEDL(_ timeline: NLETimeline) -> String {
        let fps   = timeline.frameRate
        var lines = [String]()

        // Header
        lines.append("TITLE: \(sanitizeLine(timeline.title))")
        lines.append("FCM: NON-DROP FRAME")
        lines.append("")

        var recordStart = 0.0   // cumulative record timeline offset in seconds

        for (index, clip) in timeline.clips.enumerated() {
            let eventNum = String(format: "%03d", index + 1)
            let recordEnd = recordStart + clip.duration

            let srcIn  = TimecodeFormatter.ndfTimecode(clip.inSeconds,  fps: fps)
            let srcOut = TimecodeFormatter.ndfTimecode(clip.outSeconds, fps: fps)
            let recIn  = TimecodeFormatter.ndfTimecode(recordStart,     fps: fps)
            let recOut = TimecodeFormatter.ndfTimecode(recordEnd,       fps: fps)

            // Event line: {event}  AX  V  C  {srcIn} {srcOut} {recIn} {recOut}
            lines.append("\(eventNum)  AX  V  C        \(srcIn) \(srcOut) \(recIn) \(recOut)")

            // SOURCE FILE — last path component; Resolve uses this for auto-relink
            let filename = URL(fileURLWithPath: clip.sourcePath).lastPathComponent
            lines.append("* SOURCE FILE: \(sanitizeLine(filename))")

            // FROM CLIP NAME — populates clip name in Resolve's media pool
            let clipLabel = buildClipName(id: clip.id, uploader: clip.uploader,
                                          title: clip.title, text: clip.matchedText)
            lines.append("* FROM CLIP NAME: \(sanitizeLine(clipLabel))")

            // LOC marker — Resolve places a red marker on the timeline at recIn
            if let chTitle = clip.chapterTitle {
                lines.append("* LOC: \(recIn) RED \(sanitizeLine(chTitle))")
            }

            lines.append("")
            recordStart = recordEnd
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Builds the clip display name: `"{id}. {uploader|title} — {snippet}"`.
    private static func buildClipName(id: String, uploader: String?,
                                      title: String, text: String) -> String {
        let speaker = (uploader?.isEmpty == false) ? uploader! : title
        let snippet = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        return "\(id). \(speaker) \u{2014} \(snippet)"
    }

    /// Replaces embedded newlines with a space so comment lines stay single-line.
    private static func sanitizeLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }
}
