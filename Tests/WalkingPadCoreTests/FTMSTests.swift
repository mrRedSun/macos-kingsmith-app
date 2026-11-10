import Foundation
import Testing
@testable import WalkingPadCore

struct FTMSTests {
    @Test func basicPacket() throws {
        let sample = try FTMS.decode(Data([0x04, 0x04, 0xFA, 0, 0xD2, 0x04, 0, 60, 0]))
        #expect(sample == .init(speedKmh: 2.5, distanceMeters: 1234, elapsedSeconds: 60))
        #expect(sample.steps == nil)
    }

    @Test func stepsAreExplicitlyOptIn() throws {
        let packet = Data([0x04, 0x04, 100, 0, 10, 0, 0, 5, 0, 0x34, 0x12])
        #expect(try FTMS.decode(packet).steps == nil)
        #expect(try FTMS.decode(packet, c2StepExtension: true).steps == 0x1234)
        #expect(try FTMS.decode(packet + Data([0]), c2StepExtension: true).steps == nil)
    }

    @Test func fragmentedPacketOmitsSpeed() throws {
        let result = try FTMS.decode(Data([0x05, 0x04, 42, 0, 0, 90, 0]))
        #expect(result.speedKmh == nil)
        #expect(result.distanceMeters == 42)
        #expect(result.elapsedSeconds == 90)
    }

    @Test func allOptionalFieldsAndRemainingTime() throws {
        // Flags 1...12 present, speed present. Elevation gain consumes FOUR bytes.
        var bytes: [UInt8] = [0xFE, 0x1F, 200, 0]
        bytes += [210, 0] // average speed
        bytes += [0x56, 0x34, 0x12] // distance
        bytes += Array(repeating: 0, count: 4 + 4 + 1 + 1 + 5 + 1 + 1)
        bytes += [60, 0] // elapsed
        bytes += [120, 0] // remaining, never steps
        bytes += [0, 0, 0, 0] // force, power
        let standardPacket = Data(bytes)
        #expect(try FTMS.decode(standardPacket, c2StepExtension: true).steps == nil)
        let sample = try FTMS.decode(standardPacket + Data([99, 0]), c2StepExtension: true)
        #expect(sample.speedKmh == 2)
        #expect(sample.distanceMeters == 0x123456)
        #expect(sample.elapsedSeconds == 60)
        #expect(sample.steps == 99)
        for length in 0..<standardPacket.count {
            #expect(throws: FTMS.Failure.truncated) { try FTMS.decode(standardPacket.prefix(length)) }
        }
    }

    @Test func rejectsReservedFlagsAndShortResponses() throws {
        #expect(throws: FTMS.Failure.unsupportedFlags) { try FTMS.decode(Data([0, 0x80, 0, 0])) }
        #expect(throws: FTMS.Failure.invalidResponse) { try FTMS.Response(Data([0x80, 0])) }
        #expect(throws: FTMS.Failure.invalidResponse) { try FTMS.Response(Data([0, 0, 1])) }
        let response = try FTMS.Response(Data([0x80, 0x02, 1]))
        #expect(response.opcode == 2 && response.succeeded)
        #expect(try !FTMS.Response(Data([0x80, 0, 5])).succeeded)
    }

    @Test func encodesCommandsAndRejectsUnsafeSpeeds() throws {
        #expect(FTMS.start == Data([7]))
        #expect(FTMS.stop == Data([8, 1]))
        #expect(FTMS.requestControl == Data([0]))
        #expect(try FTMS.setSpeed(2.5) == Data([2, 250, 0]))
        #expect(try FTMS.setSpeed(6) == Data([2, 0x58, 2]))
        for speed in [Double.nan, .infinity, -.infinity, -1, 0, 0.4, 6.1, 2.55] {
            #expect(throws: FTMS.Failure.invalidSpeed) { try FTMS.setSpeed(speed) }
        }
        let range = try FTMS.SpeedRange(data: Data([50, 0, 0x58, 2, 10, 0]))
        #expect(range == .conservative)
        #expect(throws: FTMS.Failure.invalidSpeed) { try FTMS.SpeedRange(data: Data([0, 0, 0, 0, 0, 0])) }
    }

    @Test func mergesFragmentsWithoutClearingKnownFields() {
        var sample = FTMS.Telemetry(speedKmh: 2, distanceMeters: 10, steps: 5)
        sample.merge(.init(elapsedSeconds: 20))
        #expect(sample == .init(speedKmh: 2, distanceMeters: 10, elapsedSeconds: 20, steps: 5))
    }
}
