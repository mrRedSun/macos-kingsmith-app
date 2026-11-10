import Foundation
import SQLite3

/// One actor owns the SQLite connection. No disk work runs on the UI actor.
public actor SessionStore {
    // The actor is the sole user. The wrapper permits safe destruction outside
    // actor isolation after the last reference is released.
    private final class Connection: @unchecked Sendable {
        let pointer: OpaquePointer?
        init(_ pointer: OpaquePointer?) { self.pointer = pointer }
        deinit { sqlite3_close(pointer) }
    }
    private let connection: Connection
    private var db: OpaquePointer? { connection.pointer }
    public struct StoreError: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            throw StoreError(message: "Cannot open the statistics database.")
        }
        sqlite3_busy_timeout(connection, 3000)
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
              sqlite3_step(versionStatement) == SQLITE_ROW else {
            sqlite3_finalize(versionStatement); sqlite3_close(connection)
            throw StoreError(message: "Cannot read the statistics database version.")
        }
        let version = sqlite3_column_int(versionStatement, 0)
        sqlite3_finalize(versionStatement)
        guard version <= 3 else {
            sqlite3_close(connection)
            throw StoreError(message: "This database requires a newer version of WalkingPad.")
        }
        let migration = (version < 2 ? "ALTER TABLE sessions ADD COLUMN estimated_time INTEGER NOT NULL DEFAULT 0;" : "")
            + (version < 3 ? """
            ALTER TABLE sessions ADD COLUMN pad_tracked INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE sessions ADD COLUMN pad_walk_id INTEGER;
            """ : "")
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS sessions (
          id TEXT PRIMARY KEY, started REAL NOT NULL, ended REAL NOT NULL,
          meters INTEGER NOT NULL, seconds INTEGER NOT NULL, steps INTEGER NOT NULL,
          has_steps INTEGER NOT NULL, revision INTEGER NOT NULL
        );
        \(migration)
        PRAGMA user_version=3;
        COMMIT;
        """
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(connection))
            sqlite3_close(connection)
            throw StoreError(message: message)
        }
        self.connection = Connection(connection)
    }

    public func save(_ session: WalkingSession) throws {
        let sql = """
        INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET started=excluded.started, ended=excluded.ended, meters=excluded.meters,
          seconds=excluded.seconds, steps=excluded.steps, has_steps=excluded.has_steps,
          revision=excluded.revision, estimated_time=excluded.estimated_time,
          pad_tracked=excluded.pad_tracked, pad_walk_id=excluded.pad_walk_id
          WHERE excluded.revision > sessions.revision;
        """
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, session.id.uuidString, -1, transient)
        sqlite3_bind_double(statement, 2, session.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, session.endedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 4, Int64(session.distanceMeters))
        sqlite3_bind_int64(statement, 5, Int64(session.seconds))
        sqlite3_bind_int64(statement, 6, Int64(session.steps))
        sqlite3_bind_int(statement, 7, session.hasSteps ? 1 : 0)
        sqlite3_bind_int64(statement, 8, Int64(session.revision))
        sqlite3_bind_int(statement, 9, session.estimatedTime ? 1 : 0)
        sqlite3_bind_int(statement, 10, session.padTracked ? 1 : 0)
        if let walk = session.padWalkID { sqlite3_bind_int64(statement, 11, Int64(walk)) }
        else { sqlite3_bind_null(statement, 11) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    public func delete(_ id: UUID) throws {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "DELETE FROM sessions WHERE id = ?", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    public func sessions() throws -> [WalkingSession] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "SELECT * FROM sessions ORDER BY started DESC", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        var rows: [WalkingSession] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: text)) else { throw error() }
            var row = WalkingSession(id: id, startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)))
            row.endedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            row.distanceMeters = Int(sqlite3_column_int64(statement, 3))
            row.seconds = Int(sqlite3_column_int64(statement, 4))
            row.steps = Int(sqlite3_column_int64(statement, 5))
            row.hasSteps = sqlite3_column_int(statement, 6) != 0
            row.revision = Int(sqlite3_column_int64(statement, 7))
            row.estimatedTime = sqlite3_column_int(statement, 8) != 0
            row.padTracked = sqlite3_column_int(statement, 9) != 0
            if sqlite3_column_type(statement, 10) != SQLITE_NULL {
                row.padWalkID = UInt32(truncatingIfNeeded: sqlite3_column_int64(statement, 10))
            }
            rows.append(row)
        }
    }

    public static func csv(_ sessions: [WalkingSession]) -> String {
        let date = ISO8601DateFormatter()
        return "id,started_at,ended_at,distance_meters,walking_seconds,steps,time_estimated\n" + sessions.map {
            "\($0.id),\(date.string(from: $0.startedAt)),\(date.string(from: $0.endedAt)),\($0.distanceMeters),\($0.seconds),\($0.hasSteps ? String($0.steps) : ""),\($0.estimatedTime ? "true" : "false")"
        }.joined(separator: "\n") + "\n"
    }
    private func check(_ status: Int32) throws { if status != SQLITE_OK { throw error() } }
    private func error() -> StoreError { StoreError(message: String(cString: sqlite3_errmsg(db))) }
}
