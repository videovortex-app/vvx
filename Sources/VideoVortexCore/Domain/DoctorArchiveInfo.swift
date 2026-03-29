import Foundation

/// Archive statistics included in `vvx doctor` JSON when `~/.vvx/vortex.db` exists.
public struct DoctorArchiveInfo: Sendable, Encodable {
    public let videoCount: Int
    public let estimatedHours: Int
    public let lastSyncedAt: String?
    public let dbPath: String
    public let dbStatus: String

    public init(
        videoCount: Int,
        estimatedHours: Int,
        lastSyncedAt: String?,
        dbPath: String,
        dbStatus: String
    ) {
        self.videoCount = videoCount
        self.estimatedHours = estimatedHours
        self.lastSyncedAt = lastSyncedAt
        self.dbPath = dbPath
        self.dbStatus = dbStatus
    }

    /// Loads stats from `~/.vvx/vortex.db` when that file already exists.
    ///
    /// Returns `nil` when the database file is absent so `doctor` does not create an empty DB.
    public static func loadFromDefaultDB() async -> DoctorArchiveInfo? {
        let dbURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vvx/vortex.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }

        let tilded = dbURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")

        guard let db = try? VortexDB(path: dbURL) else { return nil }

        do {
            let count = try await db.videoCount()
            let totalSec = try await db.totalDurationSeconds()
            let hours = max(0, totalSec / 3600)
            let last = try await db.latestSensedAt()
            let ok = try await db.integrity()
            return DoctorArchiveInfo(
                videoCount: count,
                estimatedHours: hours,
                lastSyncedAt: last,
                dbPath: tilded,
                dbStatus: ok ? "ok" : "corrupt"
            )
        } catch {
            return DoctorArchiveInfo(
                videoCount: 0,
                estimatedHours: 0,
                lastSyncedAt: nil,
                dbPath: tilded,
                dbStatus: "error"
            )
        }
    }
}
