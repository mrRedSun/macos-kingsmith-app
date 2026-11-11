import Foundation

/// Notices when nobody is walking on a moving belt.
///
/// KingSmith pads advance their time and step counters only while someone walks: on a
/// KS-BDC2 an empty belt added 2 s of time and no steps in 42 s. So a moving belt whose
/// counters stay frozen for `delay` seconds is empty.
public struct StepOffDetector: Sendable {
    /// Seconds without counter activity before the belt counts as empty.
    public var delay: TimeInterval
    /// Time after the belt starts moving to step on before anything fires.
    public var grace: TimeInterval
    private var movingSince: Date?
    private var lastActivity: Date?
    private var seconds: Int?
    private var steps: Int?
    private var fired = false

    public init(delay: TimeInterval, grace: TimeInterval = 10) {
        self.delay = delay; self.grace = grace
    }

    /// Feeds one telemetry sample. Returns true once per moving stretch, when the belt should stop.
    public mutating func update(_ telemetry: FTMS.Telemetry, at date: Date) -> Bool {
        let advanced = telemetry.elapsedSeconds != seconds || telemetry.steps != steps
        seconds = telemetry.elapsedSeconds; steps = telemetry.steps
        guard let speed = telemetry.speedKmh, speed > 0 else {
            movingSince = nil; lastActivity = nil; fired = false
            return false
        }
        if movingSince == nil { movingSince = date; lastActivity = date }
        if advanced { lastActivity = date }
        guard !fired, let movingSince, let lastActivity,
              date.timeIntervalSince(movingSince) >= grace,
              date.timeIntervalSince(lastActivity) >= delay else { return false }
        fired = true
        return true
    }

    public mutating func reset() { self = Self(delay: delay, grace: grace) }
}
