import Foundation

// MARK: - Search structural/proximity NDJSON models (Core — shared by CLI and MCP)

public struct MonologueResultLine: Encodable, Sendable {
    public let success            = true
    public let mode               = "longest_monologue"
    public let rank:               Int
    public let videoId:            String        // videoId of the source video
    public let videoTitle:         String
    public let uploader:           String?
    public let platform:           String?
    public let uploadDate:         String?
    public let videoPath:          String?
    public let startSeconds:       Double
    public let endSeconds:         Double
    public let durationSeconds:    Double
    public let blockCount:         Int
    public let structuralScore:    Double        // = durationSeconds; higher is better
    public let transcriptExcerpt:  String
    public let chapterTitle:       String?
    public let chapterIndex:       Int?
    public let isMultiChapter:     Bool
    public let reproduceCommand:   String

    public init(
        rank: Int, videoId: String, videoTitle: String, uploader: String?,
        platform: String?, uploadDate: String?, videoPath: String?,
        startSeconds: Double, endSeconds: Double, durationSeconds: Double,
        blockCount: Int, structuralScore: Double, transcriptExcerpt: String,
        chapterTitle: String?, chapterIndex: Int?, isMultiChapter: Bool,
        reproduceCommand: String
    ) {
        self.rank              = rank
        self.videoId           = videoId
        self.videoTitle        = videoTitle
        self.uploader          = uploader
        self.platform          = platform
        self.uploadDate        = uploadDate
        self.videoPath         = videoPath
        self.startSeconds      = startSeconds
        self.endSeconds        = endSeconds
        self.durationSeconds   = durationSeconds
        self.blockCount        = blockCount
        self.structuralScore   = structuralScore
        self.transcriptExcerpt = transcriptExcerpt
        self.chapterTitle      = chapterTitle
        self.chapterIndex      = chapterIndex
        self.isMultiChapter    = isMultiChapter
        self.reproduceCommand  = reproduceCommand
    }
}

public struct DensityResultLine: Encodable, Sendable {
    public let success            = true
    public let mode               = "high_density"
    public let rank:               Int
    public let videoId:            String        // videoId of the source video
    public let videoTitle:         String
    public let uploader:           String?
    public let platform:           String?
    public let uploadDate:         String?
    public let videoPath:          String?
    public let startSeconds:       Double
    public let endSeconds:         Double
    public let windowSeconds:      Double
    public let wordCount:          Int
    public let wordsPerSecond:     Double
    public let structuralScore:    Double        // = wordsPerSecond; higher is better
    public let transcriptExcerpt:  String
    public let chapterTitle:       String?
    public let chapterIndex:       Int?
    public let isMultiChapter:     Bool
    public let reproduceCommand:   String

    public init(
        rank: Int, videoId: String, videoTitle: String, uploader: String?,
        platform: String?, uploadDate: String?, videoPath: String?,
        startSeconds: Double, endSeconds: Double, windowSeconds: Double,
        wordCount: Int, wordsPerSecond: Double, structuralScore: Double,
        transcriptExcerpt: String, chapterTitle: String?, chapterIndex: Int?,
        isMultiChapter: Bool, reproduceCommand: String
    ) {
        self.rank              = rank
        self.videoId           = videoId
        self.videoTitle        = videoTitle
        self.uploader          = uploader
        self.platform          = platform
        self.uploadDate        = uploadDate
        self.videoPath         = videoPath
        self.startSeconds      = startSeconds
        self.endSeconds        = endSeconds
        self.windowSeconds     = windowSeconds
        self.wordCount         = wordCount
        self.wordsPerSecond    = wordsPerSecond
        self.structuralScore   = structuralScore
        self.transcriptExcerpt = transcriptExcerpt
        self.chapterTitle      = chapterTitle
        self.chapterIndex      = chapterIndex
        self.isMultiChapter    = isMultiChapter
        self.reproduceCommand  = reproduceCommand
    }
}

public struct StructuralSummaryLine: Encodable, Sendable {
    public let success:        Bool   = true
    public let mode:            String
    public let scannedVideos:   Int
    public let resultCount:     Int
    public let limit:           Int
    public let uploader:        String?
    public let platform:        String?
    public let afterDate:       String?

    public init(mode: String, scannedVideos: Int, resultCount: Int, limit: Int,
                uploader: String?, platform: String?, afterDate: String?) {
        self.mode          = mode
        self.scannedVideos = scannedVideos
        self.resultCount   = resultCount
        self.limit         = limit
        self.uploader      = uploader
        self.platform      = platform
        self.afterDate     = afterDate
    }
}

public struct ProximityTermHitLine: Encodable, Sendable {
    public let term:         String
    public let startSeconds: Double
    public let text:         String

    public init(term: String, startSeconds: Double, text: String) {
        self.term         = term
        self.startSeconds = startSeconds
        self.text         = text
    }
}

public struct ProximityResultLine: Encodable, Sendable {
    public let success:               Bool   = true
    public let mode:                  String = "proximity"
    public let rank:                   Int
    public let videoId:                String
    public let videoTitle:             String
    public let uploader:               String?
    public let platform:               String?
    public let uploadDate:             String?
    public let videoPath:              String?
    public let startSeconds:           Double
    public let endSeconds:             Double
    public let proximitySpanSeconds:   Double
    public let withinSeconds:          Double
    public let terms:                  [String]
    public let termHits:               [ProximityTermHitLine]
    public let structuralScore:        Double   // = proximitySpanSeconds; LOWER is better
    public let transcriptExcerpt:      String
    public let reproduceCommand:       String

    public init(
        rank: Int, videoId: String, videoTitle: String, uploader: String?,
        platform: String?, uploadDate: String?, videoPath: String?,
        startSeconds: Double, endSeconds: Double, proximitySpanSeconds: Double,
        withinSeconds: Double, terms: [String], termHits: [ProximityTermHitLine],
        structuralScore: Double, transcriptExcerpt: String, reproduceCommand: String
    ) {
        self.rank                 = rank
        self.videoId              = videoId
        self.videoTitle           = videoTitle
        self.uploader             = uploader
        self.platform             = platform
        self.uploadDate           = uploadDate
        self.videoPath            = videoPath
        self.startSeconds         = startSeconds
        self.endSeconds           = endSeconds
        self.proximitySpanSeconds = proximitySpanSeconds
        self.withinSeconds        = withinSeconds
        self.terms                = terms
        self.termHits             = termHits
        self.structuralScore      = structuralScore
        self.transcriptExcerpt    = transcriptExcerpt
        self.reproduceCommand     = reproduceCommand
    }
}

public struct ProximitySummaryLine: Encodable, Sendable {
    public let success:          Bool   = true
    public let mode:             String = "proximity"
    public let terms:             [String]
    public let withinSeconds:     Double
    public let candidateVideos:   Int
    public let resultCount:       Int
    public let limit:             Int
    public let uploader:          String?
    public let platform:          String?
    public let afterDate:         String?

    public init(terms: [String], withinSeconds: Double, candidateVideos: Int,
                resultCount: Int, limit: Int, uploader: String?,
                platform: String?, afterDate: String?) {
        self.terms           = terms
        self.withinSeconds   = withinSeconds
        self.candidateVideos = candidateVideos
        self.resultCount     = resultCount
        self.limit           = limit
        self.uploader        = uploader
        self.platform        = platform
        self.afterDate       = afterDate
    }
}
