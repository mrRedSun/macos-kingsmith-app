import Foundation
import Testing
@testable import WalkingPadCore

struct LegacyProtocolTests {
    // Independent on-wire fixture. Distance is 123 * 10 m; steps are 0x0001C8.
    private let reply = Data([0xF8, 0xA2, 1, 25, 1, 0, 0, 60, 0, 0, 123, 0, 1, 200,
                              0, 0, 0, 0, 0x3D, 0xFD])

    // Captured from an idle KS-BDC2 in reply to the statistics query.
    private let capturedIdle = Data([0xF8, 0xA2, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 1, 0, 0xA9, 0xFD])

    @Test func encodesExactCommandsAndChecksums() throws {
        // The query is the frame KS-BDC2 exposes on FE01 and answers. Motor commands
        // follow the A1 reference library: speed is opcode 1, Stop is speed 0.
        #expect(try LegacyProtocol.Command.statistics.encoded() == Data([0xF7, 0xA2, 0, 0, 0xA2, 0xFD]))
        #expect(try LegacyProtocol.Command.start.encoded() == Data([0xF7, 0xA2, 4, 1, 0xA7, 0xFD]))
        #expect(try LegacyProtocol.Command.stop.encoded() == Data([0xF7, 0xA2, 1, 0, 0xA3, 0xFD]))
        #expect(try LegacyProtocol.Command.speed(2.5).encoded() == Data([0xF7, 0xA2, 1, 25, 0xBC, 0xFD]))
        for speed in [Double.nan, .infinity, -1, 0, 0.4, 6.1, 2.55] {
            #expect(throws: (any Error).self) { try LegacyProtocol.Command.speed(speed).encoded() }
        }
    }
    @Test func decodesCountersAndStepsWithoutAnFTMSExtension() throws {
        let sample = try LegacyProtocol.decode(reply)
        #expect(sample == .init(speedKmh: 2.5, distanceMeters: 1230, elapsedSeconds: 60, steps: 456))
        var decoder = LegacyProtocol.StreamDecoder()
        #expect(decoder.append(capturedIdle) == [.status(.init(speedKmh: 0, distanceMeters: 0, elapsedSeconds: 0, steps: 0))])
    }
    @Test func rejectsInvalidChecksumsHeadersAndTruncation() {
        for length in 0..<reply.count {
            #expect(throws: (any Error).self) { try LegacyProtocol.decode(reply.prefix(length)) }
        }
        var corrupt = reply
        corrupt[11] = 100
        #expect(throws: LegacyProtocol.Failure.invalidChecksum) { try LegacyProtocol.decode(corrupt) }
        corrupt = reply; corrupt[0] = 0
        #expect(throws: LegacyProtocol.Failure.invalidFrame) { try LegacyProtocol.decode(corrupt) }
    }
    @Test func handlesEverySplitAndCoalescedNotifications() throws {
        let sample = try LegacyProtocol.decode(reply)
        for split in 1..<reply.count {
            var decoder = LegacyProtocol.StreamDecoder()
            #expect(decoder.append(reply.prefix(split)).isEmpty)
            #expect(decoder.append(reply.suffix(reply.count - split)) == [.status(sample)])
        }
        var decoder = LegacyProtocol.StreamDecoder()
        #expect(decoder.append(reply + reply) == [.status(sample), .status(sample)])
    }
    @Test func recoversFromCorruptionAndPartialHeaderNoise() throws {
        let sample = try LegacyProtocol.decode(reply)
        var decoder = LegacyProtocol.StreamDecoder()
        #expect(decoder.append(Data([0, 0xF8, 0xA2, 0xF8, 0xA2])).isEmpty)
        #expect(decoder.append(reply) == [.status(sample)])
        var corrupt = reply; corrupt[10] ^= 1
        #expect(decoder.append(corrupt + reply) == [.status(sample)])
        #expect(decoder.append(Data(repeating: 0xF8, count: 10_000)).isEmpty)
        #expect(decoder.append(reply) == [.status(sample)])
    }
    @Test func ignoresCommandEchoesAndAcceptsF7StatusVariant() throws {
        var decoder = LegacyProtocol.StreamDecoder()
        #expect(decoder.append(try LegacyProtocol.Command.start.encoded()).isEmpty)
        #expect(decoder.append(reply).count == 1)
        var variant = reply; variant[0] = 0xF7
        #expect(try LegacyProtocol.decode(variant).steps == 456)
    }
}

struct PadRecordTests {
    // Captured from KS-BDC2 after Stop: a 37:29 walk, 1.87 km, 3,007 steps. The same walk
    // resumed for 3 s kept its ID. Queries during a walk return zeros.
    private let captured = Data([0xF8, 0xA7, 0x6A, 0x07, 0x8D, 0x65, 0x08, 0xC9, 0x00, 0xBB, 0x0B, 0xBF,
                                 0x00, 0x00, 0x2D, 0x6C, 0x00, 0x00, 0xF9, 0xFD])
    private let resumed = Data([0xF8, 0xA7, 0x6A, 0x07, 0x8D, 0x65, 0x08, 0xCC, 0x00, 0xBB, 0x0B, 0xBF,
                                0x00, 0x00, 0x2D, 0x70, 0x00, 0x00, 0x00, 0xFD])
    private let empty = Data([0xF8, 0xA7] + [UInt8](repeating: 0, count: 16) + [0xA7, 0xFD])

    @Test func encodesTheHistoryQuery() throws {
        #expect(try LegacyProtocol.Command.history.encoded() == Data([0xF7, 0xA7, 0xAA, 0xFF, 0x50, 0xFD]))
        #expect(!LegacyProtocol.Command.history.isMotorCommand)
    }
    @Test func decodesCapturedRecords() throws {
        let walk = LegacyProtocol.Record(walkID: 0x6A07_8D65, seconds: 2249, distanceMeters: 1870, steps: 3007)
        #expect(try LegacyProtocol.decodeFrame(captured) == .record(walk))
        var later = walk; later.seconds = 2252
        #expect(try LegacyProtocol.decodeFrame(resumed) == .record(later))
        #expect(try LegacyProtocol.decodeFrame(empty) == .record(nil))
        var corrupt = captured; corrupt[7] ^= 1
        #expect(throws: LegacyProtocol.Failure.invalidChecksum) { try LegacyProtocol.decodeFrame(corrupt) }
    }
    @Test func streamSeparatesRecordsFromStatus() throws {
        let status = Data([0xF8, 0xA2, 0, 0, 1, 0, 0x08, 0xC9, 0, 0, 0xBB, 0, 0x0B, 0xBF, 0, 0, 3, 0, 0xFC, 0xFD])
        var decoder = LegacyProtocol.StreamDecoder()
        let frames = decoder.append(status + captured.prefix(9))
        #expect(frames == [.status(.init(speedKmh: 0, distanceMeters: 1870, elapsedSeconds: 2249, steps: 3007))])
        #expect(decoder.append(captured.dropFirst(9)).count == 1)
    }
    @Test func historyIsAPollThatNeverWaitsBehindMotorCommands() throws {
        var queue = LegacyWriteQueue()
        _ = try queue.request(.speed(2))
        #expect(try queue.request(.history) == nil)
        #expect(queue.complete() == nil)
        #expect(try queue.request(.history) == .history)
        #expect(!queue.busy)
        #expect(try queue.request(.start) == nil)
    }
}

struct LegacyQueueTests {
    @Test func startSwitchesToManualModeFirst() throws {
        // KS-BDC2 ignores Start in standby (mode 2) and starts after manual mode.
        #expect(try LegacyProtocol.Command.manualMode.encoded() == Data([0xF7, 0xA2, 2, 1, 0xA5, 0xFD]))
        var queue = LegacyWriteQueue()
        #expect(try queue.request(.start) == .manualMode)
        #expect(queue.busy)
        #expect(queue.complete() == .start)
        #expect(queue.complete() == nil)
        #expect(!queue.busy)
    }
    @Test func stopReplacesAQueuedStartAndTimeoutNeverStarts() throws {
        var queue = LegacyWriteQueue()
        _ = try queue.request(.start)
        #expect(try queue.request(.stop) == nil)
        #expect(queue.complete() == .stop)
        #expect(queue.complete() == nil)
        _ = try queue.request(.start)
        #expect(queue.timeout() == nil)
        _ = try queue.request(.statistics)
        #expect(try queue.request(.start) == nil)
        #expect(queue.complete() == .manualMode)
        #expect(queue.complete() == .start)
    }
    @Test func pollingDoesNotBlockOrOverwriteStop() throws {
        var queue = LegacyWriteQueue()
        #expect(try queue.request(.statistics) == .statistics)
        #expect(!queue.busy)
        #expect(try queue.request(.start) == nil)
        #expect(try queue.request(.stop) == nil)
        #expect(queue.busy && queue.stopQueued)
        #expect(try queue.request(.statistics) == nil)
        #expect(queue.complete() == .stop)
        #expect(queue.complete() == nil)
        #expect(!queue.busy)
    }
    @Test func motorCommandsSerializeAndTimeoutOnlyDrainsStop() throws {
        var queue = LegacyWriteQueue()
        _ = try queue.request(.speed(2))
        #expect(throws: (any Error).self) { try queue.request(.start) }
        _ = try queue.request(.stop)
        #expect(queue.timeout() == .stop)
        #expect(queue.timeout() == nil)
        _ = try queue.request(.statistics)
        _ = try queue.request(.start)
        #expect(queue.timeout() == nil) // Never start after a failed poll.
        #expect(queue.inFlight == nil && queue.pending.isEmpty)
    }
}

struct MetricPreferencesTests {
    @Test func fourUniqueRowsWithTogglesEvenWhenAllMetricsAreEnabled() {
        let rows = MetricPreferences.rows(["speed", "steps", "distance", "duration"])
        #expect(rows.count == 4)
        #expect(Set(rows).count == 4)
        #expect(rows == Metric.allCases)
    }
    @Test func preservesOrderAndKeepsDisabledMetricsReachable() {
        #expect(MetricPreferences.rows(["steps", "speed"]) == [.steps, .speed, .distance, .duration])
        #expect(MetricPreferences.rows([]) == Metric.allCases)
        #expect(MetricPreferences.rows(["speed", "speed", "invalid"]).count == 4)
        #expect(MetricPreferences.enabled(["steps", "invalid", "steps"]) == [.steps])
    }
}
