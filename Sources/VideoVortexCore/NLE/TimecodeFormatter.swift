import Foundation

// MARK: - TimecodeFormatter

/// Converts seconds to NDF (Non-Drop Frame) SMPTE timecode strings and integer frame counts.
///
/// Used by `PremiereXMLWriter` (frame counts) and `ResolveEDLWriter` (HH:MM:SS:FF strings).
///
/// **NDF frame math:**
/// - Total frames computed using the actual frame rate (e.g. 29.97).
/// - Display decomposition uses the nominal (rounded) frame rate (e.g. 30 for 29.97).
/// - This is standard NDF practice: compute against actual rate, display against nominal.
///
/// Drop-frame timecode is not supported — NDF is correct for editor cut assembly workflows.
public enum TimecodeFormatter {

    // MARK: - Public API

    /// Returns the total integer frame count for a duration in seconds at the given fps.
    ///
    /// Uses `floor` to stay on the NDF frame boundary.
    ///
    /// - Parameters:
    ///   - seconds: Duration or timecode offset in seconds. Must be ≥ 0.
    ///   - fps: Actual frame rate (e.g. `29.97`, `24.0`, `25.0`). Must be > 0.
    /// - Returns: `Int(floor(seconds × fps))`, or `0` if `fps ≤ 0`.
    public static func frameCount(_ seconds: Double, fps: Double) -> Int {
        guard fps > 0, seconds >= 0 else { return 0 }
        return Int(floor(seconds * fps))
    }

    /// Returns a SMPTE NDF timecode string (`"HH:MM:SS:FF"`) for a duration in seconds.
    ///
    /// Frame decomposition uses the nominal (rounded) fps so the FF component stays
    /// within `[0 … nominalFps-1]` — e.g. 29.97 → nominal 30, so FF ∈ 0–29.
    ///
    /// - Parameters:
    ///   - seconds: Duration or timecode offset in seconds. Must be ≥ 0.
    ///   - fps: Actual frame rate (e.g. `29.97`). Must be > 0.
    /// - Returns: Zero-padded `"HH:MM:SS:FF"` string, or `"00:00:00:00"` on invalid input.
    public static func ndfTimecode(_ seconds: Double, fps: Double) -> String {
        guard fps > 0, seconds >= 0 else { return "00:00:00:00" }

        let total      = frameCount(seconds, fps: fps)
        let nominal    = max(1, Int(fps.rounded()))

        let ff = total % nominal
        let ss = (total / nominal) % 60
        let mm = (total / (nominal * 60)) % 60
        let hh = total / (nominal * 3600)

        return String(format: "%02d:%02d:%02d:%02d", hh, mm, ss, ff)
    }
}
