import Foundation
import Testing
@testable import WalkingPadCore

struct PadWalkTests {
    private let t0 = Date(timeIntervalSince1970: 1_794_300_000)
    private func sample(_ seconds: Int, _ meters: Int, _ steps: Int, speed: Double = 3) -> FTMS.Telemetry {
        .init(speedKmh: speed, distanceMeters: meters, elapsedSeconds: seconds, steps: steps)
    }

    @Test func reconnectingMidWalkKeepsTheWholeWalk() throws {
        // Connected late: the pad has already counted 10 minutes.
        let first = try #require(PadWalks.ingest(sample(600, 500, 800), at: t0, latest: nil, continuing: false))
        #expect(first.seconds == 600 && first.distanceMeters == 500 && first.steps == 800)
        #expect(first.startedAt == t0.addingTimeInterval(-600) && first.padTracked)
        // Disconnected for 5 minutes, then reconnected while still walking.
        let later = t0.addingTimeInterval(300)
        let resumed = try #require(PadWalks.ingest(sample(900, 750, 1200), at: later, latest: first, continuing: false))
        #expect(resumed.id == first.id)
        #expect(resumed.seconds == 900 && resumed.distanceMeters == 750 && resumed.steps == 1200)
        #expect(resumed.endedAt == later && resumed.revision == first.revision + 1)
    }
    @Test func idlePadShowingTheSameWalkChangesNothing() throws {
        let walk = try #require(PadWalks.ingest(sample(600, 500, 800), at: t0, latest: nil, continuing: false))
        let hoursLater = t0.addingTimeInterval(4 * 3600)
        let same = try #require(PadWalks.ingest(sample(600, 500, 800, speed: 0), at: hoursLater, latest: walk, continuing: false))
        #expect(same == walk)
        #expect(PadWalks.ingest(sample(0, 0, 0, speed: 0), at: hoursLater, latest: walk, continuing: false) == nil)
    }
    @Test func resetCountersOrALaterLargerWalkStartANewSession() throws {
        let walk = try #require(PadWalks.ingest(sample(600, 500, 800), at: t0, latest: nil, continuing: false))
        let reset = try #require(PadWalks.ingest(sample(5, 0, 6), at: t0.addingTimeInterval(60), latest: walk, continuing: true))
        #expect(reset.id != walk.id)
        // Next day, a longer walk happened while disconnected.
        let tomorrow = t0.addingTimeInterval(86_400)
        let other = try #require(PadWalks.ingest(sample(1200, 900, 1500), at: tomorrow, latest: walk, continuing: false))
        #expect(other.id != walk.id && other.startedAt == tomorrow.addingTimeInterval(-1200))
    }
    @Test func recordCompletesTheLiveWalkAndLearnsThePadClock() throws {
        let live = try #require(PadWalks.ingest(sample(2240, 1860, 3000), at: t0, latest: nil, continuing: false))
        let record = LegacyProtocol.Record(walkID: 1_778_879_845, seconds: 2249, distanceMeters: 1870, steps: 3007)
        let merge = PadWalks.apply(record, at: t0.addingTimeInterval(10), sessions: [live], live: live.id, clockOffset: nil)
        #expect(merge.session.id == live.id && merge.removed == nil)
        #expect(merge.session.seconds == 2249 && merge.session.steps == 3007 && merge.session.padWalkID == record.walkID)
        #expect(merge.clockOffset == live.startedAt.timeIntervalSince1970 - 1_778_879_845)
        // The pad answers every later query with the same record.
        let again = PadWalks.apply(record, at: t0.addingTimeInterval(20), sessions: [merge.session], live: live.id, clockOffset: nil)
        #expect(again.session == merge.session)
    }
    @Test func recordMergesASplitWalkAndDatesUnseenWalks() throws {
        var known = WalkingSession(startedAt: t0)
        known.padTracked = true; known.padWalkID = 42; known.seconds = 600; known.endedAt = t0.addingTimeInterval(600)
        var split = WalkingSession(startedAt: t0.addingTimeInterval(3600))
        split.padTracked = true; split.seconds = 900; split.endedAt = t0.addingTimeInterval(3700)
        let record = LegacyProtocol.Record(walkID: 42, seconds: 950, distanceMeters: 700, steps: 1100)
        let merged = PadWalks.apply(record, at: t0.addingTimeInterval(3800), sessions: [split, known], live: split.id, clockOffset: nil)
        #expect(merged.session.id == known.id && merged.removed == split.id)
        #expect(merged.session.seconds == 950 && merged.session.endedAt == split.endedAt)

        let unseen = LegacyProtocol.Record(walkID: 1000, seconds: 300, distanceMeters: 200, steps: 400)
        let now = t0.addingTimeInterval(90_000)
        let dated = PadWalks.apply(unseen, at: now, sessions: [], live: nil, clockOffset: t0.timeIntervalSince1970 - 1000)
        #expect(dated.session.startedAt == t0 && dated.session.seconds == 300 && dated.session.padWalkID == 1000)
        let undated = PadWalks.apply(unseen, at: now, sessions: [], live: nil, clockOffset: nil)
        #expect(undated.session.startedAt == now.addingTimeInterval(-300))
    }
}
