import Foundation
import Testing
@testable import WalkingPadCore

struct ControlQueueTests {
    @Test func staleTelemetryDoesNotBlockStop() throws {
        var queue = ControlQueue()
        #expect(try queue.request(FTMS.stop, hasControl: true, fresh: false) == FTMS.stop)
    }
    @Test func stopHasPriorityAndIsNotSentConcurrently() throws {
        var queue = ControlQueue()
        let speed = try FTMS.setSpeed(2)
        #expect(try queue.request(speed, hasControl: true, fresh: true) == speed)
        #expect(try queue.request(FTMS.stop, hasControl: true, fresh: false) == nil)
        #expect(queue.stopQueued)
        #expect(throws: (any Error).self) { try queue.request(FTMS.start, hasControl: true, fresh: true) }
        #expect(queue.complete(opcode: 2, hasControl: true) == FTMS.stop)
        #expect(queue.pendingOpcode == 8)
        #expect(!queue.stopQueued)
        #expect(queue.complete(opcode: 8, hasControl: true) == nil)
        #expect(!queue.busy)
    }
    @Test func timeoutMakesOneStopAttemptAndNeverRetriesStart() throws {
        var queue = ControlQueue()
        _ = try queue.request(FTMS.start, hasControl: true, fresh: true)
        _ = try queue.request(FTMS.stop, hasControl: true, fresh: true)
        #expect(queue.timeout(hasControl: true) == FTMS.stop)
        #expect(queue.timeout(hasControl: true) == nil)
        #expect(!queue.busy)
    }
    @Test func rejectsUnsafeCommandsAndClearsOnControlLoss() throws {
        var queue = ControlQueue()
        #expect(throws: (any Error).self) { try queue.request(FTMS.start, hasControl: false, fresh: true) }
        #expect(throws: (any Error).self) { try queue.request(FTMS.start, hasControl: true, fresh: false) }
        _ = try queue.request(FTMS.start, hasControl: true, fresh: true)
        _ = try queue.request(FTMS.stop, hasControl: true, fresh: true)
        #expect(queue.complete(opcode: 99, hasControl: true) == nil)
        #expect(queue.busy)
        #expect(queue.complete(opcode: 7, hasControl: false) == nil)
        #expect(!queue.busy && !queue.stopQueued)
        queue.reset()
        #expect(!queue.busy)
    }
}
