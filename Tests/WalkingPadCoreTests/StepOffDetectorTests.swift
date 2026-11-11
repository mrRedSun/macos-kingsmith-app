import Foundation
import Testing
@testable import WalkingPadCore

struct StepOffDetectorTests {
    let start = Date(timeIntervalSince1970: 1_000)

    /// Feeds one sample per second; `walking(t)` decides whether counters advance at second t.
    func run(_ detector: inout StepOffDetector, seconds: Range<Int>, speed: Double = 3,
             base: inout (time: Int, steps: Int), walking: (Int) -> Bool) -> Int? {
        for t in seconds {
            if walking(t) { base.time += 1; base.steps += 2 }
            let sample = FTMS.Telemetry(speedKmh: speed, distanceMeters: 0, elapsedSeconds: base.time, steps: base.steps)
            if detector.update(sample, at: start.addingTimeInterval(Double(t))) { return t }
        }
        return nil
    }

    @Test func stopsFiveSecondsAfterTheWalkerStepsOff() {
        var detector = StepOffDetector(delay: 5)
        var base = (time: 100, steps: 200)
        let fired = run(&detector, seconds: 0..<120, base: &base) { $0 < 60 }
        #expect(fired == 64) // last advance at t=59
    }

    @Test func keepsRunningWhileSomeoneWalks() {
        var detector = StepOffDetector(delay: 5)
        var base = (time: 0, steps: 0)
        let fired = run(&detector, seconds: 0..<300, base: &base) { _ in true }
        #expect(fired == nil)
    }

    @Test func stepsAloneCountAsWalking() {
        var detector = StepOffDetector(delay: 5)
        var steps = 0
        for t in 0..<60 {
            steps += 2
            let sample = FTMS.Telemetry(speedKmh: 2, distanceMeters: 0, elapsedSeconds: 7, steps: steps)
            let fired = detector.update(sample, at: start.addingTimeInterval(Double(t)))
            #expect(!fired)
        }
    }

    @Test func givesTimeToStepOnAfterStart() {
        // Matches the KS-BDC2 capture: two seconds counted while starting, then nothing.
        var detector = StepOffDetector(delay: 5, grace: 10)
        var base = (time: 2250, steps: 3007)
        let fired = run(&detector, seconds: 0..<60, base: &base) { $0 < 2 }
        #expect(fired == 10)
    }

    @Test func firesOnceUntilTheBeltStopsAndRestarts() {
        var detector = StepOffDetector(delay: 5, grace: 0)
        var base = (time: 0, steps: 0)
        let first = run(&detector, seconds: 0..<10, base: &base) { _ in false }
        let repeated = run(&detector, seconds: 10..<30, base: &base) { _ in false }
        _ = run(&detector, seconds: 30..<31, speed: 0, base: &base) { _ in false }
        let afterRestart = run(&detector, seconds: 31..<45, base: &base) { _ in false }
        #expect(first == 5)
        #expect(repeated == nil)
        #expect(afterRestart == 36)
    }

    @Test func ignoresSamplesWithoutSpeed() {
        var detector = StepOffDetector(delay: 5, grace: 0)
        for t in 0..<30 {
            let sample = FTMS.Telemetry(speedKmh: nil, elapsedSeconds: 5, steps: 5)
            let fired = detector.update(sample, at: start.addingTimeInterval(Double(t)))
            #expect(!fired)
        }
    }
}
