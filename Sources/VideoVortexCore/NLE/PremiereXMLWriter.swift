import Foundation

// MARK: - PremiereXMLWriter

/// Pure XMEML v4 document generator for Adobe Premiere Pro.
///
/// - No file I/O: `write(_:)` returns `Data`; the caller writes to disk.
/// - No console output: all errors are thrown.
/// - No ffmpeg: references existing archive files by absolute `file://` URI.
/// - Asset deduplication: one full `<file>` definition per unique `sourcePath`;
///   subsequent clips referencing the same source use an id-only `<file id="…"/>` element.
/// - Clip name: `"{id}. {uploader|title} — {first ~80 chars of matched text}"` (XML-escaped).
/// - Chapter markers: `<marker>` inside `<clipitem>` when `chapterTitle` is non-nil.
/// - Matched text: appears as `<mastercomment1>` inside each `<clipitem>`.
/// - Time values: integer frame counts via `TimecodeFormatter.frameCount(_:fps:)`.
/// - NTSC flag: `<ntsc>TRUE</ntsc>` for fractional rates (29.97, 23.976); FALSE for integers.
public enum PremiereXMLWriter {

    // MARK: - Errors

    public enum PremiereXMLError: Error {
        case encodingFailed
    }

    // MARK: - Public entry point

    /// Encodes `timeline` as a UTF-8 XMEML v4 document.
    public static func write(_ timeline: NLETimeline) throws -> Data {
        let xml = buildDocument(timeline)
        guard let data = xml.data(using: .utf8) else {
            throw PremiereXMLError.encodingFailed
        }
        return data
    }

    // MARK: - Document builder

    private static func buildDocument(_ timeline: NLETimeline) -> String {
        let clips   = timeline.clips
        let fps     = timeline.frameRate
        let ntsc    = isNtsc(fps)
        let nominal = Int(fps.rounded())
        let ntscStr = ntsc ? "TRUE" : "FALSE"

        // --- File deduplication ------------------------------------------------
        // One full <file> definition per unique sourcePath, ordered by first appearance.
        var fileIdForPath: [String: String] = [:]
        var nextFileId = 1

        for clip in clips where fileIdForPath[clip.sourcePath] == nil {
            fileIdForPath[clip.sourcePath] = "file-\(nextFileId)"
            nextFileId += 1
        }

        // Track which file IDs have already been written as full definitions.
        var writtenFileIds = Set<String>()

        // --- Sequence total duration in frames --------------------------------
        let totalFrames = clips.reduce(0) {
            $0 + TimecodeFormatter.frameCount($1.duration, fps: fps)
        }

        var out = ""
        out += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<xmeml version=\"4\">\n"
        out += "  <sequence>\n"
        out += "    <name>\(xmlText(timeline.title))</name>\n"
        out += "    <duration>\(totalFrames)</duration>\n"
        out += rateBlock(nominal: nominal, ntsc: ntscStr, indent: "    ")
        out += "    <media>\n"
        out += "      <video>\n"
        out += "        <format>\n"
        out += "          <samplecharacteristics>\n"
        out += rateBlock(nominal: nominal, ntsc: ntscStr, indent: "            ")
        out += "          </samplecharacteristics>\n"
        out += "        </format>\n"
        out += "        <track>\n"

        // --- Clips -------------------------------------------------------------
        var clipIndex   = 1
        var timelineOff = 0   // cumulative record offset in frames

        for clip in clips {
            guard let fileId = fileIdForPath[clip.sourcePath] else { continue }

            let clipFrames = TimecodeFormatter.frameCount(clip.duration,    fps: fps)
            let inFrames   = TimecodeFormatter.frameCount(clip.inSeconds,   fps: fps)
            let outFrames  = TimecodeFormatter.frameCount(clip.outSeconds,  fps: fps)
            let startFrame = timelineOff
            let endFrame   = timelineOff + clipFrames
            let clipName   = buildClipName(id: clip.id, uploader: clip.uploader,
                                           title: clip.title, text: clip.matchedText)
            let comment    = xmlText(String(clip.matchedText.prefix(200)))

            out += "          <clipitem id=\"clip-\(clipIndex)\">\n"
            out += "            <name>\(clipName)</name>\n"
            out += "            <duration>\(clipFrames)</duration>\n"
            out += rateBlock(nominal: nominal, ntsc: ntscStr, indent: "            ")
            out += "            <start>\(startFrame)</start>\n"
            out += "            <end>\(endFrame)</end>\n"
            out += "            <in>\(inFrames)</in>\n"
            out += "            <out>\(outFrames)</out>\n"

            // File reference — full definition on first use; id-only ref thereafter.
            if writtenFileIds.contains(fileId) {
                out += "            <file id=\"\(fileId)\"/>\n"
            } else {
                writtenFileIds.insert(fileId)
                let fname   = xmlText(String(clip.title.prefix(255)))
                let pathurl = fileURI(clip.sourcePath)
                let srcDur  = clip.sourceDurationSeconds
                    .map { "\(TimecodeFormatter.frameCount($0, fps: fps))" } ?? "0"

                out += "            <file id=\"\(fileId)\">\n"
                out += "              <name>\(fname)</name>\n"
                out += "              <pathurl>\(pathurl)</pathurl>\n"
                out += rateBlock(nominal: nominal, ntsc: ntscStr, indent: "              ")
                out += "              <duration>\(srcDur)</duration>\n"
                out += "            </file>\n"
            }

            // Chapter marker
            if let chTitle = clip.chapterTitle {
                out += "            <marker>\n"
                out += "              <name>\(xmlText(chTitle))</name>\n"
                out += "              <in>\(inFrames)</in>\n"
                out += "              <out>\(inFrames)</out>\n"
                out += "            </marker>\n"
            }

            // Transcript snippet in clip comment
            out += "            <comments>\n"
            out += "              <mastercomment1>\(comment)</mastercomment1>\n"
            out += "            </comments>\n"
            out += "          </clipitem>\n"

            timelineOff += clipFrames
            clipIndex   += 1
        }

        out += "        </track>\n"
        out += "      </video>\n"
        out += "    </media>\n"
        out += "  </sequence>\n"
        out += "</xmeml>\n"

        return out
    }

    // MARK: - Helpers

    /// Builds the `<rate>` XML block at the given indent level.
    private static func rateBlock(nominal: Int, ntsc: String, indent: String) -> String {
        "\(indent)<rate>\n"
        + "\(indent)  <timebase>\(nominal)</timebase>\n"
        + "\(indent)  <ntsc>\(ntsc)</ntsc>\n"
        + "\(indent)</rate>\n"
    }

    /// Returns `true` when `fps` is fractional (e.g. 29.97, 23.976).
    private static func isNtsc(_ fps: Double) -> Bool {
        abs(fps - fps.rounded()) > 0.001
    }

    /// Builds the clip display name: `"{id}. {uploader|title} — {snippet}"`.
    private static func buildClipName(id: String, uploader: String?,
                                      title: String, text: String) -> String {
        let speaker = (uploader?.isEmpty == false) ? uploader! : title
        let snippet = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        return xmlText("\(id). \(speaker) \u{2014} \(snippet)")
    }

    /// Converts an absolute path to a percent-encoded `file:///` URI.
    private static func fileURI(_ path: String) -> String {
        let expanded     = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return URL(fileURLWithPath: standardized).absoluteString
    }

    /// Escapes a string for XML text content (between tags).
    private static func xmlText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
