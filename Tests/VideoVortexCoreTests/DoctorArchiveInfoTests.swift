import Foundation
import Testing
import VideoVortexCore

@Suite("DoctorArchiveInfo")
struct DoctorArchiveInfoTests {

    @Test("JSON encoding uses lastSyncedAt, not legacy harvest wording")
    func testJSONUsesLastSyncedAtKey() throws {
        let info = DoctorArchiveInfo(
            videoCount: 2,
            estimatedHours: 1,
            lastSyncedAt: "2026-03-26T12:00:00Z",
            dbPath: "~/.vvx/vortex.db",
            dbStatus: "ok"
        )
        let data = try JSONEncoder().encode(info)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"lastSyncedAt\":\"2026-03-26T12:00:00Z\""))
        #expect(!json.contains("lastHarvestedAt"))
    }
}
