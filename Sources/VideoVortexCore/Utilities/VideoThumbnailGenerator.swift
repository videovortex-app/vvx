import Foundation

#if os(macOS)
import AVFoundation
import AppKit
#endif

/// Extracts a JPEG preview frame from a video file.
/// On macOS: uses AVFoundation (fast, no subprocess).
/// On Linux: uses ffmpeg subprocess (requires ffmpeg on PATH).
public enum VideoThumbnailGenerator {

    /// Writes a JPEG preview to `destinationURL`.
    /// Throws `ThumbnailError.noFrame` if extraction fails or ffmpeg is unavailable.
    /// Throws `ThumbnailError.encodeFailed` if JPEG encoding fails (macOS only).
    public static func writeJPEGPreview(from videoURL: URL, to destinationURL: URL) throws {
#if os(macOS)
        let asset     = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let attempts: [CMTime] = [
            CMTime(seconds: 1, preferredTimescale: 600),
            .zero
        ]

        var cgImage: CGImage?
        for t in attempts {
            do {
                cgImage = try generator.copyCGImage(at: t, actualTime: nil)
                break
            } catch {
                continue
            }
        }
        guard let cg = cgImage else {
            throw ThumbnailError.noFrame
        }

        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            throw ThumbnailError.encodeFailed
        }
        try data.write(to: destinationURL, options: .atomic)
#else
        try writeJPEGPreviewFFmpeg(from: videoURL, to: destinationURL)
#endif
    }

    public enum ThumbnailError: Error {
        case noFrame
        case encodeFailed
        case ffmpegNotFound
    }

    // MARK: - Cross-platform ffmpeg implementation (Linux + macOS fallback)

    private static func writeJPEGPreviewFFmpeg(from videoURL: URL, to destinationURL: URL) throws {
        guard let ffmpegURL = resolveFFmpeg() else {
            throw ThumbnailError.ffmpegNotFound
        }

        // Try at 1 second first, then fall back to 0 seconds for very short videos.
        for offset in ["1", "0"] {
            let proc = Process()
            proc.executableURL = ffmpegURL
            proc.arguments = ["-y", "-ss", offset, "-i", videoURL.path,
                               "-vframes", "1", "-q:v", "3", destinationURL.path]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError  = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus == 0,
               FileManager.default.fileExists(atPath: destinationURL.path) {
                return
            }
        }
        throw ThumbnailError.noFrame
    }

    private static func resolveFFmpeg() -> URL? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: "\(dir)/ffmpeg")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
