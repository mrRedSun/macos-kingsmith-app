import Foundation
import Testing
@testable import WalkingPadCore

struct SessionBoundaryTests {
    @Test func midnightStartsANewDailySessionWithoutDroppingDeltas() {
        var tracker = SessionAccumulator()
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86400)
        _ = tracker.ingest(.init(speedKmh: 2, distanceMeters: 10, elapsedSeconds: 10), at: day1)
        let first = tracker.ingest(.init(speedKmh: 2, distanceMeters: 20, elapsedSeconds: 20), at: day1.addingTimeInterval(10))
        let second = tracker.ingest(.init(speedKmh: 2, distanceMeters: 30, elapsedSeconds: 30), at: day2)
        #expect(first?.id != second?.id)
        #expect(second?.distanceMeters == 10)
        #expect(second?.seconds == 10)
    }

    @Test func firstPacketDoesNotSaveAnEmptySession() {
        var tracker = SessionAccumulator()
        #expect(tracker.ingest(.init(speedKmh: 2, distanceMeters: 100, elapsedSeconds: 100)) == nil)
        #expect(tracker.session == nil)
    }

    @Test func estimatesTimeOnlyWhenDeviceNeverSuppliedAClock() {
        var tracker = SessionAccumulator()
        let start = Date(timeIntervalSince1970: 100)
        _ = tracker.ingest(.init(speedKmh: 2), at: start)
        let second = tracker.ingest(.init(speedKmh: 2), at: start.addingTimeInterval(5))
        #expect(second?.seconds == 5)
        _ = tracker.ingest(.init(elapsedSeconds: 100), at: start.addingTimeInterval(6))
        // This is a fragment without elapsed time, not another five seconds to add.
        #expect(tracker.ingest(.init(speedKmh: 2), at: start.addingTimeInterval(10)) == nil)
        let last = tracker.ingest(.init(elapsedSeconds: 105), at: start.addingTimeInterval(11))
        #expect(last?.seconds == 10)
    }
}
