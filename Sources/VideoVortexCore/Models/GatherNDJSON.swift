import Foundation

// MARK: - Gather NDJSON models (Core — shared by CLI and MCP)

public struct GatherClipSuccess: Encodable, Sendable {
    public let success                = true
    public let outputPath:             String
    public let inputPath:              String
    public let videoId:                String
    public let title:                  String
    public let uploader:               String?
    public let startTime:              String        // HH:MM:SS
    public let endTime:                String
    public let durationSeconds:        Double
    public let resolvedStartSeconds:   Double
    public let resolvedEndSeconds:     Double
    public let padSeconds:             Double
    public let paddedStartSeconds:     Double
    public let paddedEndSeconds:       Double
    public let plannedSrtPath:         String?
    public let matchedText:            String        // first 200 chars
    public let method:                 String        // "copy" | "default" | "exact"
    public let sizeBytes:              Int64?
    public let snapApplied:            String
    public let thumbnailPath:          String?
    public let embedSourceApplied:     Bool
    public let embedSourceNote:        String?
    public let encodeMode:             String
    public let chapterTitle:           String?
    public let chapterIndex:           Int?

    public init(
        outputPath: String, inputPath: String, videoId: String, title: String,
        uploader: String?, startTime: String, endTime: String, durationSeconds: Double,
        resolvedStartSeconds: Double, resolvedEndSeconds: Double, padSeconds: Double,
        paddedStartSeconds: Double, paddedEndSeconds: Double, plannedSrtPath: String?,
        matchedText: String, method: String, sizeBytes: Int64?, snapApplied: String,
        thumbnailPath: String?, embedSourceApplied: Bool, embedSourceNote: String?,
        encodeMode: String, chapterTitle: String?, chapterIndex: Int?
    ) {
        self.outputPath           = outputPath
        self.inputPath            = inputPath
        self.videoId              = videoId
        self.title                = title
        self.uploader             = uploader
        self.startTime            = startTime
        self.endTime              = endTime
        self.durationSeconds      = durationSeconds
        self.resolvedStartSeconds = resolvedStartSeconds
        self.resolvedEndSeconds   = resolvedEndSeconds
        self.padSeconds           = padSeconds
        self.paddedStartSeconds   = paddedStartSeconds
        self.paddedEndSeconds     = paddedEndSeconds
        self.plannedSrtPath       = plannedSrtPath
        self.matchedText          = matchedText
        self.method               = method
        self.sizeBytes            = sizeBytes
        self.snapApplied          = snapApplied
        self.thumbnailPath        = thumbnailPath
        self.embedSourceApplied   = embedSourceApplied
        self.embedSourceNote      = embedSourceNote
        self.encodeMode           = encodeMode
        self.chapterTitle         = chapterTitle
        self.chapterIndex         = chapterIndex
    }
}

public struct GatherClipFailure: Encodable, Sendable {
    public let success    = false
    public let error:      VvxError
    public let videoId:    String
    public let startTime:  String
    public let endTime:    String

    public init(error: VvxError, videoId: String, startTime: String, endTime: String) {
        self.error     = error
        self.videoId   = videoId
        self.startTime = startTime
        self.endTime   = endTime
    }
}

public struct GatherDryRunEntry: Encodable, Sendable {
    public let success                 = true
    public let dryRun                  = true
    public let plannedOutputPath:       String
    public let inputPath:               String
    public let videoId:                 String
    public let title:                   String
    public let uploader:                String?
    public let startTime:               String
    public let endTime:                 String
    public let resolvedStartSeconds:    Double
    public let resolvedEndSeconds:      Double
    public let padSeconds:              Double
    public let paddedStartSeconds:      Double
    public let paddedEndSeconds:        Double
    public let plannedDurationSeconds:  Double
    public let plannedSrtPath:          String
    public let matchedText:             String
    public let snapApplied:             String
    public let plannedThumbnailPath:    String?
    public let embedSourcePlanned:      Bool
    public let encodeMode:              String
    public let chapterTitle:            String?
    public let chapterIndex:            Int?

    public init(
        plannedOutputPath: String, inputPath: String, videoId: String, title: String,
        uploader: String?, startTime: String, endTime: String,
        resolvedStartSeconds: Double, resolvedEndSeconds: Double, padSeconds: Double,
        paddedStartSeconds: Double, paddedEndSeconds: Double, plannedDurationSeconds: Double,
        plannedSrtPath: String, matchedText: String, snapApplied: String,
        plannedThumbnailPath: String?, embedSourcePlanned: Bool, encodeMode: String,
        chapterTitle: String?, chapterIndex: Int?
    ) {
        self.plannedOutputPath      = plannedOutputPath
        self.inputPath              = inputPath
        self.videoId                = videoId
        self.title                  = title
        self.uploader               = uploader
        self.startTime              = startTime
        self.endTime                = endTime
        self.resolvedStartSeconds   = resolvedStartSeconds
        self.resolvedEndSeconds     = resolvedEndSeconds
        self.padSeconds             = padSeconds
        self.paddedStartSeconds     = paddedStartSeconds
        self.paddedEndSeconds       = paddedEndSeconds
        self.plannedDurationSeconds = plannedDurationSeconds
        self.plannedSrtPath         = plannedSrtPath
        self.matchedText            = matchedText
        self.snapApplied            = snapApplied
        self.plannedThumbnailPath   = plannedThumbnailPath
        self.embedSourcePlanned     = embedSourcePlanned
        self.encodeMode             = encodeMode
        self.chapterTitle           = chapterTitle
        self.chapterIndex           = chapterIndex
    }
}

public struct GatherEmptySummary: Encodable, Sendable {
    public let success     = true
    public let totalClips  = 0
    public let query:       String

    public init(query: String) { self.query = query }
}

public struct GatherBudgetSkipEntry: Encodable, Sendable {
    public let success                 = false
    public let skipped                 = true
    public let reason                  = "budget_exceeded"
    public let videoId:                 String
    public let startTime:               String
    public let endTime:                 String
    public let plannedDurationSeconds:  Double

    public init(videoId: String, startTime: String, endTime: String, plannedDurationSeconds: Double) {
        self.videoId                = videoId
        self.startTime              = startTime
        self.endTime                = endTime
        self.plannedDurationSeconds = plannedDurationSeconds
    }
}

/// Final line always emitted by GatherEngine.run().
/// CLI: prints as last NDJSON line (additive — makes gather scriptable).
/// MCP: agent reads outputDir + manifestPath from this line.
/// `Codable` so the CLI can decode the final NDJSON line for `--open` (manifest path is not required).
public struct GatherSummaryLine: Codable, Sendable {
    public let success:       Bool   // always true when emitted by GatherEngine
    public let summary:       Bool   // always true when emitted by GatherEngine
    public let succeeded:     Int
    public let failed:        Int
    public let total:         Int
    public let dryRun:        Bool
    public let outputDir:     String
    public let manifestPath:  String?   // null for dryRun or zero-success runs

    public init(succeeded: Int, failed: Int, total: Int, dryRun: Bool,
                outputDir: String, manifestPath: String?) {
        self.success      = true
        self.summary      = true
        self.succeeded    = succeeded
        self.failed       = failed
        self.total        = total
        self.dryRun       = dryRun
        self.outputDir    = outputDir
        self.manifestPath = manifestPath
    }
}
