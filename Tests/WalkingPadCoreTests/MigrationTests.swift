import Foundation
import Testing
import SQLite3
@testable import WalkingPadCore

struct MigrationTests {
    @Test func versionOneDatabaseMigratesWithoutLosingRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("walkingpad-migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stats.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let id = UUID()
        let sql = """
        CREATE TABLE sessions (id TEXT PRIMARY KEY, started REAL NOT NULL, ended REAL NOT NULL,
          meters INTEGER NOT NULL, seconds INTEGER NOT NULL, steps INTEGER NOT NULL,
          has_steps INTEGER NOT NULL, revision INTEGER NOT NULL);
        INSERT INTO sessions VALUES ('\(id)', 100, 110, 20, 10, 30, 1, 1);
        PRAGMA user_version=1;
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let store = try SessionStore(url: url)
        var rows = try await store.sessions()
        #expect(rows.count == 1)
        #expect(rows[0].id == id)
        #expect(rows[0].distanceMeters == 20)
        #expect(!rows[0].estimatedTime)
        #expect(!rows[0].padTracked && rows[0].padWalkID == nil)
        rows[0].estimatedTime = true; rows[0].revision = 2
        rows[0].padTracked = true; rows[0].padWalkID = 0xFFFF_FFFF; rows[0].startedAt = Date(timeIntervalSince1970: 90)
        try await store.save(rows[0])
        let reopened = try SessionStore(url: url)
        #expect(try await reopened.sessions() == rows)
        try await reopened.delete(id)
        #expect(try await reopened.sessions().isEmpty)
    }

    @Test func futureSchemaIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("walkingpad-future-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stats.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(throws: (any Error).self) { try SessionStore(url: url) }
    }
}
