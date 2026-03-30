import CryptoKit
import Foundation

// MARK: - FCPXMLWriter

/// Pure FCPXML 1.9 document generator.
///
/// - No file I/O: `write(_:)` returns `Data`; the caller writes to disk.
/// - No console output: all errors are thrown.
/// - No ffmpeg: references existing archive files by absolute `file://` URI.
/// - Asset deduplication: one `<asset>` per unique `sourcePath`.
/// - Clip name: `"{id}. {uploader|title} — {first ~80 chars of matched text}"`
/// - Chapter markers: `<marker>` at clip in-point when `chapterTitle` is non-nil.
/// - Matched text: appears as `<note>` inside each `<clip>`.
public enum FCPXMLWriter {

    // MARK: - Errors

    public enum FCPXMLError: Error {
        case encodingFailed
    }

    // MARK: - Public entry point

    /// Encodes `timeline` as a UTF-8 FCPXML 1.9 document.
    public static func write(_ timeline: NLETimeline) throws -> Data {
        let xml = buildDocument(timeline)
        guard let data = xml.data(using: .utf8) else {
            throw FCPXMLError.encodingFailed
        }
        return data
    }

    // MARK: - Document builder

    private static func buildDocument(_ timeline: NLETimeline) -> String {
        let clips = timeline.clips

        // --- Asset deduplication ------------------------------------------------
        // One <asset> per unique sourcePath, ordered by first appearance.
        var assetIdForPath: [String: String] = [:]   // sourcePath → "r{N}"
        var seenPaths: [String] = []                 // ordered for deterministic output
        var nextId = 2

        for clip in clips {
            if assetIdForPath[clip.sourcePath] == nil {
                assetIdForPath[clip.sourcePath] = "r\(nextId)"
                seenPaths.append(clip.sourcePath)
                nextId += 1
            }
        }

        // --- Shared values -------------------------------------------------------
        let fd          = frameDuration(fps: timeline.frameRate)
        let totalDur    = clips.reduce(0.0) { $0 + $1.duration }
        let formatName  = fcpFormatName(fps: timeline.frameRate)
        let projectUID  = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: timeline.generatedAt)

        let eventName   = xmlAttrEscape("VVX: \(timeline.title) \(dateStr)")
        let projectName = xmlAttrEscape(timeline.title)

        // --- Build asset map: sourcePath → NLEClip (first occurrence) -----------
        var firstClipForPath: [String: NLEClip] = [:]
        for clip in clips {
            if firstClipForPath[clip.sourcePath] == nil {
                firstClipForPath[clip.sourcePath] = clip
            }
        }

        // --- Assemble XML --------------------------------------------------------
        var out = ""

        out += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<!DOCTYPE fcpxml>\n"
        out += "<fcpxml version=\"1.9\">\n"

        // resources
        out += "  <resources>\n"
        out += "    <format id=\"r1\" name=\"\(formatName)\" frameDuration=\"\(fd)\""
        out += " width=\"1920\" height=\"1080\" colorSpace=\"1-1-1 (Rec. 709)\"/>\n"

        for path in seenPaths {
            guard let assetId = assetIdForPath[path],
                  let firstClip = firstClipForPath[path] else { continue }

            let src     = fileURI(path)
            let name    = xmlAttrEscape(String(firstClip.title.prefix(255)))
            let uid     = stableUID(for: firstClip.sourceUrl)
            let durAttr = firstClip.sourceDurationSeconds.map { fcpTime($0) } ?? "0s"

            out += "    <asset id=\"\(assetId)\" name=\"\(name)\" uid=\"\(uid)\""
            out += " src=\"\(src)\" start=\"0s\" duration=\"\(durAttr)\""
            out += " hasVideo=\"1\" hasAudio=\"1\">\n"
            out += "      <media-rep kind=\"original-media\" src=\"\(src)\"/>\n"
            out += "    </asset>\n"
        }

        out += "  </resources>\n"

        // library / event / project / sequence / spine
        out += "  <library>\n"
        out += "    <event name=\"\(eventName)\">\n"
        out += "      <project name=\"\(projectName)\" uid=\"\(projectUID)\">\n"
        out += "        <sequence format=\"r1\" duration=\"\(fcpTime(totalDur))\""
        out += " tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">\n"
        out += "          <spine>\n"

        var timelineOffset = 0.0
        for clip in clips {
            guard let assetId = assetIdForPath[clip.sourcePath] else { continue }

            let clipName = buildClipName(id: clip.id,
                                         uploader: clip.uploader,
                                         title: clip.title,
                                         text: clip.matchedText)
            let offsetStr  = fcpTime(timelineOffset)
            let durStr     = fcpTime(clip.duration)
            let startStr   = fcpTime(clip.inSeconds)
            let noteText   = xmlTextEscape(String(clip.matchedText.prefix(200)))

            out += "            <clip name=\"\(clipName)\" ref=\"\(assetId)\""
            out += " offset=\"\(offsetStr)\" duration=\"\(durStr)\" start=\"\(startStr)\">\n"
            out += "              <note>\(noteText)</note>\n"

            if let chTitle = clip.chapterTitle {
                let markerValue = xmlAttrEscape(chTitle)
                out += "              <marker start=\"\(startStr)\" duration=\"\(fd)\""
                out += " value=\"\(markerValue)\"/>\n"
            }

            out += "            </clip>\n"

            timelineOffset += clip.duration
        }

        out += "          </spine>\n"
        out += "        </sequence>\n"
        out += "      </project>\n"
        out += "    </event>\n"
        out += "  </library>\n"
        out += "</fcpxml>\n"

        return out
    }

    // MARK: - Clip name

    /// `"{id}. {uploader|title} \u{2014} {first ~80 chars of text}"` — XML-escaped.
    private static func buildClipName(id: String,
                                       uploader: String?,
                                       title: String,
                                       text: String) -> String {
        let speaker = (uploader?.isEmpty == false) ? uploader! : title
        let snippet = String(text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80))
        // U+2014 is the em dash — matches spec
        return xmlAttrEscape("\(id). \(speaker) \u{2014} \(snippet)")
    }

    // MARK: - Time helpers (internal for testing)

    /// Converts seconds to a FCPXML rational time string.
    /// - Whole seconds → `"Ns"`
    /// - Fractional seconds → `"<ms>/1000s"`
    ///
    /// Examples: `30.0` → `"30s"`, `59.5` → `"59500/1000s"`, `0.0` → `"0s"`.
    static func fcpTime(_ seconds: Double) -> String {
        // Round to nearest millisecond to avoid floating-point drift.
        let ms = (seconds * 1000).rounded()
        let totalMs = Int64(ms)
        let wholeSeconds = totalMs / 1000
        let remainder    = totalMs % 1000
        if remainder == 0 {
            return "\(wholeSeconds)s"
        }
        return "\(totalMs)/1000s"
    }

    /// Returns the FCPXML `frameDuration` rational string for a given fps.
    static func frameDuration(fps: Double) -> String {
        switch fps {
        case 23.976: return "1001/24000s"
        case 24.0:   return "1/24s"
        case 25.0:   return "1/25s"
        case 29.97:  return "1001/30000s"
        case 30.0:   return "1/30s"
        case 50.0:   return "1/50s"
        case 59.94:  return "1001/60000s"
        case 60.0:   return "1/60s"
        default:
            let rounded = max(1, Int(fps.rounded()))
            return "1/\(rounded)s"
        }
    }

    // MARK: - Format name

    private static func fcpFormatName(fps: Double) -> String {
        switch fps {
        case 23.976: return "FFVideoFormat1080p2398"
        case 24.0:   return "FFVideoFormat1080p24"
        case 25.0:   return "FFVideoFormat1080p25"
        case 29.97:  return "FFVideoFormat1080p2997"
        case 30.0:   return "FFVideoFormat1080p30"
        case 50.0:   return "FFVideoFormat1080p50"
        case 59.94:  return "FFVideoFormat1080p5994"
        case 60.0:   return "FFVideoFormat1080p60"
        default:     return "FFVideoFormat1080p2997"
        }
    }

    // MARK: - Stable UID

    /// Deterministic 32-char lowercase hex UID derived from `sourceUrl` via SHA-256.
    /// Stable across re-runs for the same source URL — FCP uses UIDs for reconform/relink.
    static func stableUID(for sourceUrl: String) -> String {
        let digest = SHA256.hash(data: Data(sourceUrl.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - File URI

    /// Converts an absolute path (tilde-expanded, standardized) to a `file://` URI.
    private static func fileURI(_ path: String) -> String {
        let expanded     = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return URL(fileURLWithPath: standardized).absoluteString
    }

    // MARK: - XML escaping

    /// Escapes a string for use in XML attribute values (double-quoted attributes).
    static func xmlAttrEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&",  with: "&amp;")
         .replacingOccurrences(of: "<",  with: "&lt;")
         .replacingOccurrences(of: ">",  with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Escapes a string for use in XML text content (between tags).
    static func xmlTextEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
