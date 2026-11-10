import Testing
@testable import WalkingPadCore

struct SpeedControlTests {
    let range = FTMS.SpeedRange.conservative

    @Test func stepsByHalfKilometreToTheNextMark() {
        #expect(SpeedControl.adjust(3.0, by: 1, imperial: false, range: range) == 3.5)
        #expect(SpeedControl.adjust(3.3, by: 1, imperial: false, range: range) == 3.5)
        #expect(SpeedControl.adjust(3.3, by: -1, imperial: false, range: range) == 3.0)
        #expect(SpeedControl.adjust(3.5, by: -2, imperial: false, range: range) == 2.5)
    }
    @Test func clampsToThePadRange() {
        #expect(SpeedControl.adjust(6.0, by: 1, imperial: false, range: range) == 6.0)
        #expect(SpeedControl.adjust(0.5, by: -1, imperial: false, range: range) == 0.5)
        #expect(SpeedControl.adjust(1.0, by: -1, imperial: false, range: range) == 0.5)
    }
    @Test func imperialStepsByHalfMileAndNeverSticks() {
        var kmh = SpeedControl.snap(2.0 * 1.609344, range: range)
        #expect(kmh == 3.2)
        #expect(SpeedControl.label(kmh, imperial: true) == "2.0")
        for expected in ["2.5", "3.0", "3.5"] {
            kmh = SpeedControl.adjust(kmh, by: 1, imperial: true, range: range)
            #expect(SpeedControl.label(kmh, imperial: true) == expected)
        }
        kmh = SpeedControl.adjust(kmh, by: -1, imperial: true, range: range)
        #expect(SpeedControl.label(kmh, imperial: true) == "3.0")
    }
    @Test func everyResultIsAValidCommand() throws {
        let coarse = FTMS.SpeedRange(minimum: 1.0, maximum: 6.0, increment: 0.2)
        for imperial in [false, true] {
            var kmh = coarse.minimum
            for _ in 0..<20 {
                kmh = SpeedControl.adjust(kmh, by: 1, imperial: imperial, range: coarse)
                _ = try FTMS.setSpeed(kmh, range: coarse)
            }
        }
    }
    @Test func presetsFallBackAndSnap() {
        #expect(SpeedControl.presets(nil, range: range) == [2, 3, 4, 5])
        #expect(SpeedControl.presets([1, 2], range: range) == [2, 3, 4, 5])
        #expect(SpeedControl.presets([0.1, 2.04, 3, 9], range: range) == [0.5, 2.0, 3, 6])
    }
}
