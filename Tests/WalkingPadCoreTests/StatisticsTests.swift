import Foundation
import Testing
@testable import WalkingPadCore

struct StatisticsTests {
    @Test func doesNotImportExistingCounters() {
        var tracker = SessionAccumulator()
        let first = tracker.ingest(.init(speedKmh: 2, distanceMeters: 1000, elapsedSeconds: 600, steps: 500))
        #expect(first == nil)
        #expect(tracker.session == nil)
        let second = tracker.ingest(.init(speedKmh: 2, distanceMeters: 1010, elapsedSeconds: 605, steps: 510))
        #expect(second != nil)
        #expect(second?.distanceMeters == 10)
        #expect(second?.seconds == 5)
        #expect(second?.steps == 10)
    }

    @Test func timeOnlyFragmentsUseLastKnownSpeed() {
        var tracker = SessionAccumulator()
        _ = tracker.ingest(.init(speedKmh: 2, elapsedSeconds: 100))
        let second = tracker.ingest(.init(elapsedSeconds: 105))
        #expect(second?.seconds == 5)
    }

    @Test func idleDoesNotCreateSessionsOrAddWalkingTime() {
        var tracker = SessionAccumulator()
        #expect(tracker.ingest(.init(speedKmh: 0, elapsedSeconds: 100)) == nil)
        #expect(tracker.ingest(.init(speedKmh: 0, elapsedSeconds: 200)) == nil)
        _ = tracker.ingest(.init(speedKmh: 2, elapsedSeconds: 201))
        let stopped = tracker.ingest(.init(speedKmh: 0, elapsedSeconds: 300))
        #expect(stopped == nil)
        #expect(tracker.session?.seconds == 1)
    }

    @Test func resetAndRepeatedPacketsDoNotDoubleCount() {
        var tracker = SessionAccumulator()
        let sample = FTMS.Telemetry(speedKmh: 2, distanceMeters: 100, elapsedSeconds: 100, steps: 100)
        _ = tracker.ingest(sample)
        #expect(tracker.ingest(sample) == nil)
        #expect(tracker.session == nil)
        _ = tracker.ingest(.init(speedKmh: 2, distanceMeters: 0, elapsedSeconds: 0, steps: 0))
        let after = tracker.ingest(.init(speedKmh: 2, distanceMeters: 5, elapsedSeconds: 2, steps: 4))
        #expect(after?.steps == 4)
        #expect(after?.distanceMeters == 5)
        tracker.reset()
        #expect(tracker.session == nil)
        #expect(tracker.ingest(sample) == nil)
    }

    @Test func missingFieldsHaveIndependentBaselines() {
        var tracker = SessionAccumulator()
        _ = tracker.ingest(.init(speedKmh: 1))
        _ = tracker.ingest(.init(distanceMeters: 200))
        _ = tracker.ingest(.init(steps: 300))
        let result = tracker.ingest(.init(distanceMeters: 202, steps: 304))
        #expect(result?.distanceMeters == 2)
        #expect(result?.steps == 4)
        tracker.resetStepBaseline()
        #expect(tracker.ingest(.init(steps: 1000)) == nil)
        #expect(tracker.session?.steps == 4)
    }

    @Test func formattingUnavailableAndImperialMetrics() {
        #expect(DisplayFormat.speed(nil, imperial: false) == "—")
        #expect(DisplayFormat.distance(1609, imperial: true) == "1.00 mi")
        #expect(DisplayFormat.duration(3661) == "1:01:01")
        #expect(DisplayFormat.duration(nil) == "—")
    }
}

struct StoreTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("walkingpad-test-\(UUID())/stats.sqlite")
    }

    @Test func persistsAcrossConnectionsAndIgnoresOldRevisions() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(url: url)
        var session = WalkingSession(startedAt: Date(timeIntervalSince1970: 100))
        session.distanceMeters = 123; session.steps = 456; session.hasSteps = true; session.revision = 2
        session.estimatedTime = true
        try await store.save(session)
        var stale = session
        stale.steps = 1; stale.revision = 1
        try await store.save(stale)
        let reopened = try SessionStore(url: url)
        #expect(try await reopened.sessions() == [session])
    }

    @Test func concurrentSnapshotsCannotRegressTotals() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(url: url)
        let id = UUID()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in (1...100).reversed() {
                group.addTask {
                    var session = WalkingSession(id: id, startedAt: Date(timeIntervalSince1970: 100))
                    session.revision = revision; session.distanceMeters = revision
                    try await store.save(session)
                }
            }
            try await group.waitForAll()
        }
        let rows = try await store.sessions()
        #expect(rows.count == 1)
        #expect(rows.first?.distanceMeters == 100)
    }

    @Test func csvUsesStandardUnitsAndBlankUnavailableSteps() {
        var session = WalkingSession(startedAt: Date(timeIntervalSince1970: 0))
        session.distanceMeters = 100; session.seconds = 60
        let csv = SessionStore.csv([session])
        #expect(csv.contains("distance_meters,walking_seconds,steps,time_estimated\n"))
        #expect(csv.contains(",100,60,,false\n"))
        #expect(csv.contains("1970-01-01T00:00:00Z"))
    }

    @Test func cannotOpenDirectoryAsDatabase() {
        #expect(throws: (any Error).self) { try SessionStore(url: FileManager.default.temporaryDirectory) }
    }
}
