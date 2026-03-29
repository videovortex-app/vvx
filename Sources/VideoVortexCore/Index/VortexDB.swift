import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#else
#error("SQLite module not found. Install sqlite3 development headers and ensure pkg-config can resolve sqlite3.")
#endif

// MARK: - SQLite constant shims
// Swift does not automatically import these C macro constants from SQLite3 headers.
private let SQLITE_TRANSIENT = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self)
// SQLITE_OPEN_READONLY (0x00000001) — defined as a macro in sqlite3.h; redefined here
// so it is available regardless of which SQLite module (SQLite3 vs CSQLite) is in use.
private let SQLITE_OPEN_READONLY_FLAG: Int32 = 0x00000001

// MARK: - Public value types

/// A video record as stored in the `videos` table.
public struct VideoRecord: Sendable, Equatable {
    public let id: String               // canonical URL (primary key)
    public let title: String
    public let platform: String?
    public let uploader: String?
    public let durationSeconds: Int?
    public let uploadDate: String?      // ISO 8601 date string
    public let transcriptPath: String?
    public let videoPath: String?       // nil if sense-only (no download)
    public let sensedAt: String         // ISO 8601
    public let archivedAt: String?      // ISO 8601, nil if sense-only
    public let tags: [String]
    public let viewCount: Int?
    /// Like count at index time (sense or fetch). Nil if the platform did not provide it.
    public let likeCount: Int?
    /// Comment count at index time. Nil if the platform did not provide it.
    public let commentCount: Int?
    public let description: String?
    /// Chapter markers from the video creator — populated from sense results.
    public let chapters: [VideoChapter]

    public init(
        id: String,
        title: String,
        platform: String? = nil,
        uploader: String? = nil,
        durationSeconds: Int? = nil,
        uploadDate: String? = nil,
        transcriptPath: String? = nil,
        videoPath: String? = nil,
        sensedAt: String,
        archivedAt: String? = nil,
        tags: [String] = [],
        viewCount: Int? = nil,
        likeCount: Int? = nil,
        commentCount: Int? = nil,
        description: String? = nil,
        chapters: [VideoChapter] = []
    ) {
        self.id              = id
        self.title           = title
        self.platform        = platform
        self.uploader        = uploader
        self.durationSeconds = durationSeconds
        self.uploadDate      = uploadDate
        self.transcriptPath  = transcriptPath
        self.videoPath       = videoPath
        self.sensedAt        = sensedAt
        self.archivedAt      = archivedAt
        self.tags            = tags
        self.viewCount       = viewCount
        self.likeCount       = likeCount
        self.commentCount    = commentCount
        self.description     = description
        self.chapters        = chapters
    }
}

/// A single FTS5 search hit returned by `VortexDB.search(...)`.
/// Context window assembly (2 blocks before / after) is handled by `SRTSearcher`.
public struct SearchHit: Sendable {
    public let videoId: String
    public let title: String
    public let platform: String?
    public let uploader: String?
    public let startTime: String        // "00:14:32,000"
    public let endTime: String
    public let startSeconds: Double
    public let text: String             // matched block text
    public let relevanceScore: Double   // bm25() — lower (more negative) = more relevant
    // Resolved from the `videos` table in the same query JOIN.
    public let videoPath: String?
    public let transcriptPath: String?
    public let uploadDate: String?
    /// Chapter markers for this video — used by `SRTSearcher` to resolve the chapter heading per hit.
    public let chapters: [VideoChapter]
}

/// Result from a read-only SQL query, preserving column order.
///
/// `columns` and each `rows[n]` are parallel arrays: `rows[n][i]` is the value
/// for `columns[i]` in row `n`.  Nil means the cell is SQL NULL.
public struct SQLQueryResult: Sendable {
    public let columns: [String]
    public let rows: [[String?]]
    public var rowCount: Int { rows.count }
}

/// A transcript block row from `transcript_blocks`, used for context window assembly.
public struct StoredBlock: Sendable, Equatable {
    public let startTime: String
    public let endTime: String
    public let startSeconds: Double
    public let text: String
}

// MARK: - Errors

public enum VortexDBError: Error, LocalizedError, Equatable {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case notReadOnly

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg):    return "VortexDB: failed to open — \(msg)"
        case .execFailed(let msg):    return "VortexDB: SQL failed — \(msg)"
        case .prepareFailed(let msg): return "VortexDB: prepare failed — \(msg)"
        case .notReadOnly:            return "VortexDB: only SELECT statements are permitted"
        }
    }
}

// MARK: - Module-private SQLite helpers
//
// These are free functions (not actor methods) so they can be called safely from
// actor `init` and `deinit` without triggering actor-isolation warnings.
// All functions take an explicit connection pointer; the VortexDB actor serialises
// access so the pointer is never used from two threads simultaneously.

private func dbExec(_ conn: OpaquePointer?, _ sql: String) throws {
    guard let conn else { throw VortexDBError.openFailed("connection is nil") }
    var errMsg: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(conn, sql, nil, nil, &errMsg)
    if rc != SQLITE_OK {
        let msg = errMsg.map { String(cString: $0) } ?? "error code \(rc)"
        sqlite3_free(errMsg)
        throw VortexDBError.execFailed(msg)
    }
}

@discardableResult
private func dbPrepare<T>(
    _ conn: OpaquePointer?,
    _ sql: String,
    _ body: (OpaquePointer) throws -> T
) throws -> T {
    guard let conn else { throw VortexDBError.openFailed("connection is nil") }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
        throw VortexDBError.prepareFailed(String(cString: sqlite3_errmsg(conn)))
    }
    defer { sqlite3_finalize(stmt) }
    return try body(stmt)
}

private func dbQueryInt(_ conn: OpaquePointer?, _ sql: String) -> Int? {
    try? dbPrepare(conn, sql) { stmt in
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}

private func dbBindOptText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String?) {
    if let value {
        sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
    } else {
        sqlite3_bind_null(stmt, idx)
    }
}

private func dbBindOptInt(_ stmt: OpaquePointer, _ idx: Int32, _ value: Int?) {
    if let value {
        sqlite3_bind_int64(stmt, idx, Int64(value))
    } else {
        sqlite3_bind_null(stmt, idx)
    }
}

private func dbColumnText(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
    guard sqlite3_column_type(stmt, idx) != SQLITE_NULL,
          let cstr = sqlite3_column_text(stmt, idx) else { return nil }
    return String(cString: cstr)
}

private func dbColumnOptInt(_ stmt: OpaquePointer, _ idx: Int32) -> Int? {
    guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int64(stmt, idx))
}

private func dbParseTags(_ json: String?) -> [String] {
    guard let json,
          let data  = json.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
    return array
}

private func dbEncodeTags(_ tags: [String]) -> String {
    guard !tags.isEmpty,
          let data = try? JSONSerialization.data(withJSONObject: tags),
          let str  = String(data: data, encoding: .utf8) else { return "[]" }
    return str
}

private func dbParseChapters(_ json: String?) -> [VideoChapter] {
    guard let json,
          let data = json.data(using: .utf8),
          let array = try? JSONDecoder().decode([VideoChapter].self, from: data) else { return [] }
    return array
}

private func dbEncodeChapters(_ chapters: [VideoChapter]) -> String {
    guard !chapters.isEmpty,
          let data = try? JSONEncoder().encode(chapters),
          let str  = String(data: data, encoding: .utf8) else { return "[]" }
    return str
}

// MARK: - Schema setup (module-level, safe to call from init)

private func dbApplySchema(_ conn: OpaquePointer?) throws {
    // Version tracking — always created first.
    try dbExec(conn, """
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER NOT NULL
        );
    """)

    let current = dbQueryInt(conn, "SELECT version FROM schema_version LIMIT 1;") ?? 0

    if current < 1 {
        try dbMigrateV1(conn)
        try dbExec(conn, "DELETE FROM schema_version;")
        try dbExec(conn, "INSERT INTO schema_version(version) VALUES (1);")
    }
    if current < 2 {
        try dbMigrateV2(conn)
        try dbExec(conn, "DELETE FROM schema_version;")
        try dbExec(conn, "INSERT INTO schema_version(version) VALUES (2);")
    }
    if current < 3 {
        try dbMigrateV3(conn)
        try dbExec(conn, "DELETE FROM schema_version;")
        try dbExec(conn, "INSERT INTO schema_version(version) VALUES (3);")
    }
    if current < 4 {
        try dbMigrateV4(conn)
        try dbExec(conn, "DELETE FROM schema_version;")
        try dbExec(conn, "INSERT INTO schema_version(version) VALUES (4);")
    }
}

private func dbMigrateV1(_ conn: OpaquePointer?) throws {
    // Primary video metadata + deduplication state.
    // `id` is the canonical URL.  `video_path` is NULL for sense-only operations.
    try dbExec(conn, """
        CREATE TABLE IF NOT EXISTS videos (
            id               TEXT PRIMARY KEY,
            title            TEXT NOT NULL,
            platform         TEXT,
            uploader         TEXT,
            upload_date      TEXT,
            duration_seconds INTEGER,
            transcript_path  TEXT,
            video_path       TEXT,
            sensed_at        TEXT,
            archived_at      TEXT,
            tags             TEXT,
            view_count       INTEGER,
            like_count       INTEGER,
            comment_count    INTEGER,
            description      TEXT
        );
    """)

    // FTS5 virtual table — one row per SRT block (~3–5 seconds of speech).
    //
    // Tokeniser: porter unicode61
    //   porter    — Porter stemmer: "running" matches "run"
    //   unicode61 — Full Unicode case folding for CJK, diacritics, etc.
    //
    // UNINDEXED columns are stored but not added to the FTS5 inverted index.
    // Only `title` and `text` participate in MATCH queries; all other columns
    // are metadata carried along for result rendering.
    //
    // Standard FTS5 mode (no `content=''`) stores all column values inline so
    // they are fully retrievable via SELECT after a MATCH query.
    try dbExec(conn, """
        CREATE VIRTUAL TABLE IF NOT EXISTS transcript_blocks USING fts5(
            video_id      UNINDEXED,
            title,
            platform      UNINDEXED,
            uploader      UNINDEXED,
            start_time    UNINDEXED,
            end_time      UNINDEXED,
            start_seconds UNINDEXED,
            text,
            tokenize = 'porter unicode61'
        );
    """)
}

private func dbMigrateV2(_ conn: OpaquePointer?) throws {
    // Add chapter markers column — stored as a JSON array of VideoChapter objects.
    // `ALTER TABLE ... ADD COLUMN` is safe on existing V1 databases; the column
    // defaults to NULL for all pre-existing rows.
    try dbExec(conn, "ALTER TABLE videos ADD COLUMN chapters TEXT;")
}

private func dbMigrateV4(_ conn: OpaquePointer?) throws {
    // Add engagement snapshot columns for Phase 3.5 viral analysis.
    // `try?` so the migration is idempotent — SQLite rejects duplicate ADD COLUMN.
    try? dbExec(conn, "ALTER TABLE videos ADD COLUMN like_count INTEGER;")
    try? dbExec(conn, "ALTER TABLE videos ADD COLUMN comment_count INTEGER;")
}

private func dbMigrateV3(_ conn: OpaquePointer?) throws {
    // FTS5 virtual tables do not support `ALTER TABLE ... ADD COLUMN`.
    // We recreate the table with the new `chapter_index UNINDEXED` column by:
    //   1. Creating a fresh FTS5 table under a temporary name.
    //   2. Copying all existing rows (chapter_index defaults to NULL; `vvx reindex`
    //      backfills it from stored SRT files + chapter metadata).
    //   3. Dropping the old table and renaming the new one.
    try dbExec(conn, "DROP TABLE IF EXISTS transcript_blocks_v3new;")
    try dbExec(conn, """
        CREATE VIRTUAL TABLE transcript_blocks_v3new USING fts5(
            video_id      UNINDEXED,
            title,
            platform      UNINDEXED,
            uploader      UNINDEXED,
            start_time    UNINDEXED,
            end_time      UNINDEXED,
            start_seconds UNINDEXED,
            chapter_index UNINDEXED,
            text,
            tokenize = 'porter unicode61'
        );
    """)
    try dbExec(conn, """
        INSERT INTO transcript_blocks_v3new
            (video_id, title, platform, uploader, start_time, end_time, start_seconds, text)
        SELECT video_id, title, platform, uploader, start_time, end_time, start_seconds, text
        FROM transcript_blocks;
    """)
    try dbExec(conn, "DROP TABLE transcript_blocks;")
    try dbExec(conn, "ALTER TABLE transcript_blocks_v3new RENAME TO transcript_blocks;")
}

// MARK: - VortexDB

/// Actor-based SQLite wrapper for `~/.vvx/vortex.db`.
///
/// All database access is serialised by the actor executor.  WAL mode +
/// `busy_timeout=5000` additionally protect against cross-process contention
/// (e.g. two simultaneous `vvx sync` runs in separate terminals).
///
/// **Usage:**
/// ```swift
/// let db = try VortexDB.open()   // uses default ~/.vvx/vortex.db path
/// try await db.upsertVideo(record)
/// let hits = try await db.search(query: "artificial intelligence")
/// ```
public actor VortexDB {

    // `nonisolated(unsafe)` allows `init` and `deinit` — which run outside the actor
    // executor — to set and close the raw C pointer.  Actual concurrent safety is
    // provided by the actor serialising all method calls.
    nonisolated(unsafe) private var db: OpaquePointer?

    /// Stored so `executeReadOnlyIsolated` can open a fresh read-only connection
    /// to the same file without requiring a second `init` call.
    private let dbPath: URL

    // MARK: - Init / Open

    /// Open (or create) the database at `path`, apply WAL pragmas, and run schema migrations.
    ///
    /// - Parameter path: Full filesystem path to the `.db` file.
    ///   The parent directory is created automatically if it does not exist.
    public init(path: URL) throws {
        self.dbPath = path

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var connection: OpaquePointer?
        guard sqlite3_open(path.path, &connection) == SQLITE_OK, let connection else {
            let msg = connection.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw VortexDBError.openFailed(msg)
        }
        self.db = connection

        // WAL mode — MANDATORY, set before any other statement.
        try dbExec(connection, "PRAGMA journal_mode=WAL;")
        // busy_timeout — MANDATORY, set immediately after WAL.
        try dbExec(connection, "PRAGMA busy_timeout=5000;")

        try dbApplySchema(connection)
    }

    deinit {
        sqlite3_close(db)
    }

    /// Convenience factory: opens `~/.vvx/vortex.db` (canonical production path).
    public static func open() throws -> VortexDB {
        let vvxDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vvx")
        return try VortexDB(path: vvxDir.appendingPathComponent("vortex.db"))
    }

    // MARK: - Write: videos

    /// Insert or update a video record in the `videos` table.
    ///
    /// On conflict (same canonical URL), all fields are updated **except**:
    /// `video_path` and `archived_at` — which preserve existing non-null values so
    /// that a re-sense never erases a previously downloaded file path.
    public func upsertVideo(_ record: VideoRecord) throws {
        let tagsJSON     = dbEncodeTags(record.tags)
        let chaptersJSON = dbEncodeChapters(record.chapters)

        let sql = """
            INSERT INTO videos
                (id, title, platform, uploader, upload_date, duration_seconds,
                 transcript_path, video_path, sensed_at, archived_at,
                 tags, view_count, like_count, comment_count, description, chapters)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title            = excluded.title,
                platform         = excluded.platform,
                uploader         = COALESCE(excluded.uploader, uploader),
                upload_date      = excluded.upload_date,
                duration_seconds = excluded.duration_seconds,
                transcript_path  = excluded.transcript_path,
                video_path       = COALESCE(excluded.video_path, video_path),
                sensed_at        = excluded.sensed_at,
                archived_at      = COALESCE(excluded.archived_at, archived_at),
                tags             = excluded.tags,
                view_count       = excluded.view_count,
                like_count       = excluded.like_count,
                comment_count    = excluded.comment_count,
                description      = excluded.description,
                chapters         = excluded.chapters;
            """

        try dbPrepare(db, sql) { stmt throws -> Void in
            sqlite3_bind_text(stmt, 1,  record.id,       -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2,  record.title,    -1, SQLITE_TRANSIENT)
            dbBindOptText(stmt, 3,  record.platform)
            dbBindOptText(stmt, 4,  record.uploader)
            dbBindOptText(stmt, 5,  record.uploadDate)
            dbBindOptInt( stmt, 6,  record.durationSeconds)
            dbBindOptText(stmt, 7,  record.transcriptPath)
            dbBindOptText(stmt, 8,  record.videoPath)
            sqlite3_bind_text(stmt, 9,  record.sensedAt, -1, SQLITE_TRANSIENT)
            dbBindOptText(stmt, 10, record.archivedAt)
            sqlite3_bind_text(stmt, 11, tagsJSON,        -1, SQLITE_TRANSIENT)
            dbBindOptInt( stmt, 12, record.viewCount)
            dbBindOptInt( stmt, 13, record.likeCount)
            dbBindOptInt( stmt, 14, record.commentCount)
            dbBindOptText(stmt, 15, record.description)
            sqlite3_bind_text(stmt, 16, chaptersJSON,    -1, SQLITE_TRANSIENT)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw VortexDBError.execFailed(String(cString: sqlite3_errmsg(stmt)))
            }
        }
    }

    // MARK: - Write: transcript_blocks

    /// Delete all existing blocks for `videoId` then insert `blocks` in a single transaction.
    ///
    /// The delete-before-insert pattern ensures re-sense idempotency: calling this twice
    /// for the same video always results in exactly one current set of blocks.
    ///
    /// - Parameter chapterIndices: Parallel array of chapter indices (one per block).
    ///   Pass `[]` when chapter indices are unavailable; all rows will store NULL.
    ///   Used by `vvx reindex` to backfill the `chapter_index` column.
    public func upsertBlocks(
        _ blocks: [SRTBlock],
        videoId: String,
        title: String,
        platform: String?,
        uploader: String?,
        chapterIndices: [Int?] = []
    ) throws {
        do {
            try dbExec(db, "BEGIN TRANSACTION;")

            try dbPrepare(db, "DELETE FROM transcript_blocks WHERE video_id = ?;") { stmt throws -> Void in
                sqlite3_bind_text(stmt, 1, videoId, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw VortexDBError.execFailed(String(cString: sqlite3_errmsg(stmt)))
                }
            }

            let insertSQL = """
                INSERT INTO transcript_blocks
                    (video_id, title, platform, uploader,
                     start_time, end_time, start_seconds, chapter_index, text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """

            for (i, block) in blocks.enumerated() {
                let chapterIdx: Int? = i < chapterIndices.count ? chapterIndices[i] : nil
                try dbPrepare(db, insertSQL) { stmt throws -> Void in
                    sqlite3_bind_text(stmt, 1, videoId,                    -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, title,                      -1, SQLITE_TRANSIENT)
                    dbBindOptText(stmt, 3, platform)
                    dbBindOptText(stmt, 4, uploader)
                    sqlite3_bind_text(stmt, 5, block.startTime,            -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 6, block.endTime,              -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 7, String(block.startSeconds), -1, SQLITE_TRANSIENT)
                    dbBindOptInt( stmt, 8, chapterIdx)
                    sqlite3_bind_text(stmt, 9, block.text,                 -1, SQLITE_TRANSIENT)

                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw VortexDBError.execFailed(String(cString: sqlite3_errmsg(stmt)))
                    }
                }
            }

            try dbExec(db, "COMMIT;")
        } catch {
            try? dbExec(db, "ROLLBACK;")
            throw error
        }
    }

    // MARK: - Read: videos

    /// Query all videos from the `videos` table, newest-sensed first.
    ///
    /// - Parameters:
    ///   - platform: Optional exact-match filter on `platform`.
    ///   - limit: Maximum rows (nil = no limit).
    public func allVideos(platform: String? = nil, limit: Int? = nil) throws -> [VideoRecord] {
        var sql = """
            SELECT id, title, platform, uploader, upload_date, duration_seconds,
                   transcript_path, video_path, sensed_at, archived_at,
                   tags, view_count, like_count, comment_count, description, chapters
            FROM videos
            """
        if platform != nil { sql += " WHERE platform = ?" }
        sql += " ORDER BY sensed_at DESC"
        if let limit { sql += " LIMIT \(limit)" }
        sql += ";"

        return try dbPrepare(db, sql) { stmt in
            if let platform {
                sqlite3_bind_text(stmt, 1, platform, -1, SQLITE_TRANSIENT)
            }
            var rows: [VideoRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(VideoRecord(
                    id:              dbColumnText(stmt, 0)   ?? "",
                    title:           dbColumnText(stmt, 1)   ?? "",
                    platform:        dbColumnText(stmt, 2),
                    uploader:        dbColumnText(stmt, 3),
                    durationSeconds: dbColumnOptInt(stmt, 5),
                    uploadDate:      dbColumnText(stmt, 4),
                    transcriptPath:  dbColumnText(stmt, 6),
                    videoPath:       dbColumnText(stmt, 7),
                    sensedAt:        dbColumnText(stmt, 8)   ?? "",
                    archivedAt:      dbColumnText(stmt, 9),
                    tags:            dbParseTags(dbColumnText(stmt, 10)),
                    viewCount:       dbColumnOptInt(stmt, 11),
                    likeCount:       dbColumnOptInt(stmt, 12),
                    commentCount:    dbColumnOptInt(stmt, 13),
                    description:     dbColumnText(stmt, 14),
                    chapters:        dbParseChapters(dbColumnText(stmt, 15))
                ))
            }
            return rows
        }
    }

    /// Total number of videos in the database.  Used by `vvx doctor`.
    public func videoCount() throws -> Int {
        dbQueryInt(db, "SELECT COUNT(*) FROM videos;") ?? 0
    }

    /// Returns `true` if a video with `id` exists in the database and has been sensed
    /// (`sensed_at IS NOT NULL`).  Used by `--incremental` sync to skip already-processed URLs.
    ///
    /// Uses `SELECT EXISTS` to avoid loading any row data — the fastest possible SQLite lookup.
    /// Called once per resolved URL in a large playlist, so performance matters.
    public func containsSensedVideo(id: String) throws -> Bool {
        try dbPrepare(db, "SELECT EXISTS(SELECT 1 FROM videos WHERE id = ? AND sensed_at IS NOT NULL);") { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_int(stmt, 0) == 1
        }
    }

    /// Number of FTS rows in `transcript_blocks` for `videoId` (canonical URL).
    /// Used to avoid wiping fetch-indexed transcripts when sense returns no blocks.
    public func transcriptBlockCount(forVideoId videoId: String) throws -> Int {
        try dbPrepare(db, "SELECT COUNT(*) FROM transcript_blocks WHERE video_id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, videoId, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Latest `sensed_at` among all videos (lexicographic max works for ISO 8601), or nil if none.
    public func latestSensedAt() throws -> String? {
        try dbPrepare(db, "SELECT MAX(sensed_at) FROM videos WHERE sensed_at IS NOT NULL AND sensed_at != '';") { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return dbColumnText(stmt, 0)
        }
    }

    /// Sum of `duration_seconds` (NULL treated as 0). Used by `vvx doctor` for estimated hours.
    public func totalDurationSeconds() throws -> Int {
        try dbPrepare(db, "SELECT IFNULL(SUM(duration_seconds), 0) FROM videos;") { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - Read: search

    /// Execute an FTS5 full-text search against `transcript_blocks`.
    ///
    /// Results are ordered by `bm25()` relevance (most relevant first).
    /// Each hit includes `video_path`, `transcript_path`, and `upload_date` from
    /// the `videos` table via a single JOIN — no second query needed.
    ///
    /// Context window assembly (2 blocks before/after each hit) is done by
    /// `SRTSearcher` (Step 4), which calls `blocksForVideo(videoId:)`.
    ///
    /// - Parameters:
    ///   - query: FTS5 query.  Supports boolean operators (`AI AND danger`),
    ///     phrase search (`"exact phrase"`), and prefix search (`intell*`).
    ///   - platform: Optional platform filter (matched against denormalised column).
    ///   - afterDate: ISO 8601 date; only hits from videos uploaded on or after this
    ///     date are included.
    ///   - uploader: Optional exact-match filter on the `uploader` column.
    ///   - limit: Maximum hits (default 50).
    public func search(
        query: String,
        platform: String? = nil,
        afterDate: String? = nil,
        uploader: String? = nil,
        limit: Int = 50
    ) throws -> [SearchHit] {
        // Named parameters (?1–?5) allow reuse of the same value in the
        // NULL-or-value filter idiom with a single binding call per parameter.
        //
        // No table aliases: SQLite FTS5 auxiliary functions (bm25) require the
        // original table name, not an alias.  Using aliases causes a
        // "no such column: <alias>" error at prepare time.
        let sql = """
            SELECT transcript_blocks.video_id,
                   transcript_blocks.title,
                   transcript_blocks.platform,
                   COALESCE(transcript_blocks.uploader, videos.uploader),
                   transcript_blocks.start_time,
                   transcript_blocks.end_time,
                   transcript_blocks.start_seconds,
                   transcript_blocks.text,
                   bm25(transcript_blocks) AS rank,
                   videos.video_path,
                   videos.transcript_path,
                   videos.upload_date,
                   videos.chapters
            FROM transcript_blocks
            JOIN videos ON transcript_blocks.video_id = videos.id
            WHERE transcript_blocks MATCH ?1
              AND (?2 IS NULL OR transcript_blocks.platform  = ?2)
              AND (?3 IS NULL OR videos.upload_date          >= ?3)
              AND (?4 IS NULL OR COALESCE(transcript_blocks.uploader, videos.uploader) = ?4)
            ORDER BY rank
            LIMIT ?5;
            """

        return try dbPrepare(db, sql) { stmt in
            sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
            dbBindOptText(stmt, 2, platform)
            dbBindOptText(stmt, 3, afterDate)
            dbBindOptText(stmt, 4, uploader)
            sqlite3_bind_int(stmt, 5, Int32(limit))

            var hits: [SearchHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                hits.append(SearchHit(
                    videoId:        dbColumnText(stmt, 0) ?? "",
                    title:          dbColumnText(stmt, 1) ?? "",
                    platform:       dbColumnText(stmt, 2),
                    uploader:       dbColumnText(stmt, 3),
                    startTime:      dbColumnText(stmt, 4) ?? "",
                    endTime:        dbColumnText(stmt, 5) ?? "",
                    startSeconds:   Double(dbColumnText(stmt, 6) ?? "0") ?? 0,
                    text:           dbColumnText(stmt, 7) ?? "",
                    relevanceScore: sqlite3_column_double(stmt, 8),
                    videoPath:      dbColumnText(stmt, 9),
                    transcriptPath: dbColumnText(stmt, 10),
                    uploadDate:     dbColumnText(stmt, 11),
                    chapters:       dbParseChapters(dbColumnText(stmt, 12))
                ))
            }
            return hits
        }
    }

    // MARK: - Read: context window support

    /// All transcript blocks for a given video, ordered by start time (ascending).
    ///
    /// Used by `SRTSearcher` to build the 2-before / 2-after context window around
    /// each search hit without re-reading the SRT file from disk.
    public func blocksForVideo(videoId: String) throws -> [StoredBlock] {
        let sql = """
            SELECT start_time, end_time, start_seconds, text
            FROM transcript_blocks
            WHERE video_id = ?
            ORDER BY CAST(start_seconds AS REAL);
            """
        return try dbPrepare(db, sql) { stmt in
            sqlite3_bind_text(stmt, 1, videoId, -1, SQLITE_TRANSIENT)
            var blocks: [StoredBlock] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                blocks.append(StoredBlock(
                    startTime:    dbColumnText(stmt, 0) ?? "",
                    endTime:      dbColumnText(stmt, 1) ?? "",
                    startSeconds: Double(dbColumnText(stmt, 2) ?? "0") ?? 0,
                    text:         dbColumnText(stmt, 3) ?? ""
                ))
            }
            return blocks
        }
    }

    // MARK: - Read: analytics / maintenance

    /// Execute a read-only SQL query and return rows as `[columnName: value]` dictionaries.
    ///
    /// Only `SELECT` statements are permitted.  Any other prefix throws
    /// `VortexDBError.notReadOnly` — the safety guard for `vvx sql`.
    public func executeReadOnly(_ sql: String) throws -> [[String: String?]] {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("SELECT") else {
            throw VortexDBError.notReadOnly
        }
        return try dbPrepare(db, trimmed) { stmt in
            let colCount = sqlite3_column_count(stmt)
            var rows: [[String: String?]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: String?] = [:]
                for i in 0..<colCount {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    row[name] = dbColumnText(stmt, i)
                }
                rows.append(row)
            }
            return rows
        }
    }

    /// Run `PRAGMA integrity_check` — returns `true` if the database is healthy.
    ///
    /// Used by `vvx doctor`.  If `false`, the fix is:
    /// `rm ~/.vvx/vortex.db && vvx reindex`
    public func integrity() throws -> Bool {
        try dbPrepare(db, "PRAGMA integrity_check;") { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return dbColumnText(stmt, 0) == "ok"
        }
    }

    /// Returns `true` when both engagement columns (`like_count`, `comment_count`) exist
    /// in the `videos` table.  Used by `vvx doctor` to confirm the Phase 3 schema migration
    /// has been applied to the live database.
    public func hasEngagementColumns() throws -> Bool {
        try dbPrepare(db, "PRAGMA table_info(videos);") { stmt in
            var columns = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = dbColumnText(stmt, 1) {
                    columns.insert(name)
                }
            }
            return columns.contains("like_count") && columns.contains("comment_count")
        }
    }

    /// Returns the active SQLite journal mode string (should be `"wal"` after init).
    public func journalMode() throws -> String {
        try dbPrepare(db, "PRAGMA journal_mode;") { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return "unknown" }
            return dbColumnText(stmt, 0) ?? "unknown"
        }
    }

    /// Returns the current schema version (used in tests and doctor checks).
    public func schemaVersion() throws -> Int {
        dbQueryInt(db, "SELECT version FROM schema_version LIMIT 1;") ?? 0
    }

    // MARK: - Read: library (vvx library)

    /// Query videos from the `videos` table with optional filters and sort order.
    ///
    /// Designed for `vvx library`.  Superset of `allVideos()` — adds `uploader`
    /// and `downloaded` filtering with deterministic `sensed_at DESC` default sort.
    ///
    /// - Parameters:
    ///   - platform: Optional exact-match filter on `platform`.
    ///   - uploader: Optional exact-match filter on `uploader`.
    ///   - downloaded: When `true`, only returns videos where `video_path IS NOT NULL`.
    ///   - limit: Maximum rows (nil = no limit).
    ///   - sort: `"newest"` (default) | `"oldest"` | `"title"` | `"duration"`.
    public func library(
        platform:   String? = nil,
        uploader:   String? = nil,
        downloaded: Bool    = false,
        limit:      Int?    = nil,
        sort:       String  = "newest"
    ) throws -> [VideoRecord] {
        var conditions: [String] = []
        var bindings:   [String] = []

        if let p = platform {
            conditions.append("platform = ?")
            bindings.append(p)
        }
        if let u = uploader {
            conditions.append("uploader = ?")
            bindings.append(u)
        }
        if downloaded {
            conditions.append("video_path IS NOT NULL")
        }

        var sql = """
            SELECT id, title, platform, uploader, upload_date, duration_seconds,
                   transcript_path, video_path, sensed_at, archived_at,
                   tags, view_count, like_count, comment_count, description, chapters
            FROM videos
            """
        if !conditions.isEmpty {
            sql += "\nWHERE " + conditions.joined(separator: " AND ")
        }

        let order: String
        switch sort.lowercased() {
        case "oldest":   order = "sensed_at ASC"
        case "title":    order = "title COLLATE NOCASE ASC"
        case "duration": order = "duration_seconds DESC"
        default:         order = "sensed_at DESC"
        }
        sql += "\nORDER BY \(order)"
        if let l = limit { sql += "\nLIMIT \(l)" }
        sql += ";"

        return try dbPrepare(db, sql) { stmt in
            for (i, value) in bindings.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), value, -1, SQLITE_TRANSIENT)
            }
            var records: [VideoRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                records.append(VideoRecord(
                    id:              dbColumnText(stmt, 0)  ?? "",
                    title:           dbColumnText(stmt, 1)  ?? "",
                    platform:        dbColumnText(stmt, 2),
                    uploader:        dbColumnText(stmt, 3),
                    durationSeconds: dbColumnOptInt(stmt, 5),
                    uploadDate:      dbColumnText(stmt, 4),
                    transcriptPath:  dbColumnText(stmt, 6),
                    videoPath:       dbColumnText(stmt, 7),
                    sensedAt:        dbColumnText(stmt, 8)  ?? "",
                    archivedAt:      dbColumnText(stmt, 9),
                    tags:            dbParseTags(dbColumnText(stmt, 10)),
                    viewCount:       dbColumnOptInt(stmt, 11),
                    likeCount:       dbColumnOptInt(stmt, 12),
                    commentCount:    dbColumnOptInt(stmt, 13),
                    description:     dbColumnText(stmt, 14),
                    chapters:        dbParseChapters(dbColumnText(stmt, 15))
                ))
            }
            return records
        }
    }

    // MARK: - Read: analytics with OS-level read-only enforcement (vvx sql)

    /// Execute a user-provided SQL query on a **fresh, OS-enforced read-only connection**.
    ///
    /// Opens a secondary `sqlite3` handle with `SQLITE_OPEN_READONLY` — even if
    /// the caller passes a `DROP TABLE` or `DELETE` statement, SQLite will reject
    /// it at the OS level before any Swift-level check runs.
    ///
    /// Additional guardrails:
    /// - The query must start with `SELECT` (case-insensitive).
    /// - Semicolons inside the body are rejected to prevent multi-statement injection.
    ///
    /// - Returns: A `SQLQueryResult` with column names and rows in query order.
    /// - Throws: `VortexDBError.notReadOnly` for non-SELECT or multi-statement input.
    public func executeReadOnlyIsolated(_ sql: String) throws -> SQLQueryResult {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip the one permitted trailing semicolon before the single-statement check.
        var body = trimmed
        if body.hasSuffix(";") {
            body = String(body.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard body.uppercased().hasPrefix("SELECT") else {
            throw VortexDBError.notReadOnly
        }
        // Reject multi-statement input (any semicolon remaining in body is a separator).
        guard !body.contains(";") else {
            throw VortexDBError.notReadOnly
        }

        // Open a fresh read-only connection — OS enforces no writes.
        var roConn: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath.path, &roConn, SQLITE_OPEN_READONLY_FLAG, nil)
        guard rc == SQLITE_OK, let roConn else {
            let msg = roConn.map { String(cString: sqlite3_errmsg($0)) } ?? "error code \(rc)"
            sqlite3_close(roConn)
            throw VortexDBError.openFailed(msg)
        }
        defer { sqlite3_close(roConn) }

        return try dbPrepare(roConn, trimmed) { stmt in
            let colCount = sqlite3_column_count(stmt)
            let columns  = (0..<colCount).map { i in
                String(cString: sqlite3_column_name(stmt, i))
            }
            var rows: [[String?]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let row = (0..<colCount).map { i in dbColumnText(stmt, i) }
                rows.append(row)
            }
            return SQLQueryResult(columns: columns, rows: rows)
        }
    }

    /// Return `CREATE TABLE` / `CREATE VIRTUAL TABLE` SQL for all tables in the database.
    ///
    /// Used by `vvx sql --schema` so agents can write correct queries without guessing
    /// column names.
    public func tableSchema() throws -> [String] {
        try dbPrepare(db, """
            SELECT sql FROM sqlite_master
            WHERE type = 'table' AND sql IS NOT NULL
            ORDER BY name;
            """) { stmt in
            var schemas: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let s = dbColumnText(stmt, 0) { schemas.append(s) }
            }
            return schemas
        }
    }
}
