import Foundation

public struct WalkingSession: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var distanceMeters: Int = 0
    public var seconds: Int = 0
    public var steps: Int = 0
    public var hasSteps: Bool = false
    public var estimatedTime: Bool = false
    public var revision: Int = 0
    /// Totals are the pad's own walk counters (KingSmith pads), not summed deltas.
    public var padTracked: Bool = false
    /// The pad's walk ID, known once the pad has returned its stored record.
    public var padWalkID: UInt32?
    public init(id: UUID = UUID(), startedAt: Date) {
        self.id = id; self.startedAt = startedAt; self.endedAt = startedAt
    }
}

/// Counts only observed counter deltas, with independent baselines for fragments.
/// The first reading and each counter reset are baselines, never imported totals.
public struct SessionAccumulator: Sendable {
    public private(set) var session: WalkingSession?
    private var distance: Int?
    private var time: Int?
    private var steps: Int?
    private var speedKmh: Double = 0
    private var lastSampleDate: Date?
    private var fractionalSeconds: Double = 0

    public init() {}

    public mutating func ingest(_ update: FTMS.Telemetry, at date: Date = Date(),
                                calendar: Calendar = .current) -> WalkingSession? {
        let previousDate = lastSampleDate
        let previousSpeed = speedKmh
        defer { lastSampleDate = date }
        let distanceDelta = delta(update.distanceMeters, previous: &distance)
        let timeDelta = delta(update.elapsedSeconds, previous: &time)
        let stepDelta = delta(update.steps, previous: &steps)
        if let speed = update.speedKmh { speedKmh = speed }
        let activity = speedKmh > 0 || distanceDelta > 0 || stepDelta > 0
        var countedTime = activity ? timeDelta : 0
        var estimated = false
        // Only estimate if this connection has NEVER supplied elapsed time.
        // Otherwise a fragment without time would double-count the next clock delta.
        if time == nil, previousSpeed > 0, speedKmh > 0, let previousDate {
            let interval = date.timeIntervalSince(previousDate)
            if interval >= 0 && interval <= 15 {
                fractionalSeconds += interval
                countedTime = Int(fractionalSeconds)
                fractionalSeconds -= Double(countedTime)
                estimated = countedTime > 0
            }
        }
        let hasDelta = distanceDelta > 0 || stepDelta > 0 || countedTime > 0
        guard session != nil || hasDelta else { return nil }
        let newDay = session.map { !calendar.isDate($0.startedAt, inSameDayAs: date) } ?? true
        let isNew = newDay && hasDelta
        if isNew {
            // Counter deltas belong to the day of their receiving sample. No
            // invented interpolation across midnight, sleep, or disconnected gaps.
            let start = previousDate.flatMap { calendar.isDate($0, inSameDayAs: date) ? $0 : nil } ?? date
            session = WalkingSession(startedAt: start)
        }
        guard var current = session else { return nil }
        let stepsBecameAvailable = update.steps != nil && !current.hasSteps
        guard isNew || hasDelta || stepsBecameAvailable else { return nil }
        current.distanceMeters += distanceDelta
        current.steps += stepDelta
        current.hasSteps = current.hasSteps || steps != nil
        current.seconds += countedTime
        current.estimatedTime = current.estimatedTime || estimated
        current.endedAt = date
        current.revision += 1
        session = current
        return current
    }

    public mutating func reset() { self = Self() }
    public mutating func resetStepBaseline() { steps = nil }

    private func delta(_ current: Int?, previous: inout Int?) -> Int {
        guard let current else { return 0 }
        defer { previous = current }
        guard let previous else { return 0 }
        return max(0, current - previous)
    }
}

/// KingSmith pads keep per-walk counters until the next walk starts and store a
/// record of each walk. Sessions mirror those counters, so reconnecting continues
/// a walk instead of losing what happened while disconnected.
public enum PadWalks {
    /// - Parameters:
    ///   - latest: the newest pad-tracked session.
    ///   - continuing: an earlier sample from this same connection already matched `latest`.
    /// Returns `latest` unchanged (same revision) when the counters match it.
    public static func ingest(_ update: FTMS.Telemetry, at date: Date, latest: WalkingSession?,
                              continuing: Bool) -> WalkingSession? {
        guard let seconds = update.elapsedSeconds, let meters = update.distanceMeters else { return nil }
        let steps = update.steps ?? 0
        guard seconds > 0 || meters > 0 || steps > 0 else { return nil }
        if var current = latest, current.padTracked,
           seconds >= current.seconds, meters >= current.distanceMeters, steps >= current.steps {
            let unchanged = seconds == current.seconds && meters == current.distanceMeters && steps == current.steps
            // Within one connection the counters only reset for a new walk. On a new
            // connection, a walk that began after the last one was seen is new even if
            // its counters are larger. A stored record later merges a wrong split.
            let estimatedStart = date.addingTimeInterval(-Double(seconds))
            if unchanged { return current }
            if continuing || estimatedStart <= current.endedAt.addingTimeInterval(120) {
                current.seconds = seconds; current.distanceMeters = meters; current.steps = steps
                current.hasSteps = current.hasSteps || update.steps != nil
                current.endedAt = date; current.revision += 1
                return current
            }
        }
        var session = WalkingSession(startedAt: date.addingTimeInterval(-Double(seconds)))
        session.endedAt = date
        session.seconds = seconds; session.distanceMeters = meters; session.steps = steps
        session.hasSteps = update.steps != nil; session.padTracked = true; session.revision = 1
        return session
    }

    public struct Merge: Equatable, Sendable {
        public var session: WalkingSession
        /// A live session that turned out to be the same walk as `session`.
        public var removed: UUID?
        /// Pad clock offset (seconds to add to a walk ID to get Unix time), when learned.
        public var clockOffset: Double?
    }

    /// Applies the pad's latest-walk record. The pad returns the same record on every
    /// query until another walk ends, so applying it again changes nothing.
    /// - Parameters:
    ///   - sessions: pad-tracked sessions, newest first.
    ///   - live: the session tracked on this connection, if any.
    ///   - clockOffset: learned from earlier walks, used to date walks the app never saw.
    public static func apply(_ record: LegacyProtocol.Record, at date: Date, sessions: [WalkingSession],
                             live: UUID?, clockOffset: Double?) -> Merge {
        let liveSession = sessions.first { $0.id == live && ($0.padWalkID == nil || $0.padWalkID == record.walkID) }
        func absorb(_ session: inout WalkingSession, _ other: WalkingSession?) {
            let before = session
            defer {
                // Re-reading an unchanged record must not rewrite the row.
                var unchanged = session; unchanged.revision = before.revision
                if other == nil, unchanged == before { session = before }
            }
            session.seconds = max(session.seconds, record.seconds, other?.seconds ?? 0)
            session.distanceMeters = max(session.distanceMeters, record.distanceMeters, other?.distanceMeters ?? 0)
            session.steps = max(session.steps, record.steps, other?.steps ?? 0)
            session.hasSteps = true
            session.endedAt = max(session.endedAt, other?.endedAt ?? session.endedAt)
            session.padWalkID = record.walkID; session.padTracked = true
            session.revision = max(session.revision, other?.revision ?? 0) + 1
        }
        if var known = sessions.first(where: { $0.padWalkID == record.walkID }) {
            // A live session started after a split reconnect is the same walk when its
            // counters fit inside the record.
            let duplicate = liveSession.flatMap {
                $0.id == known.id || $0.startedAt < known.startedAt || $0.seconds > record.seconds
                    || $0.distanceMeters > record.distanceMeters ? nil : $0
            }
            absorb(&known, duplicate)
            return Merge(session: known, removed: duplicate?.id)
        }
        if var current = liveSession, current.padWalkID == nil, current.seconds <= record.seconds {
            absorb(&current, nil)
            return Merge(session: current, clockOffset: current.startedAt.timeIntervalSince1970 - Double(record.walkID))
        }
        // A walk the app never saw. Date it from the pad clock when known.
        let start = clockOffset.map { Date(timeIntervalSince1970: Double(record.walkID) + $0) }
            .map { min($0, date.addingTimeInterval(-Double(record.seconds))) }
            ?? date.addingTimeInterval(-Double(record.seconds))
        var session = WalkingSession(startedAt: start)
        session.endedAt = start.addingTimeInterval(Double(record.seconds))
        absorb(&session, nil)
        return Merge(session: session)
    }
}

public enum Metric: String, CaseIterable, Identifiable, Sendable {
    case speed, steps, distance, duration
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum DisplayFormat {
    /// `compact` drops the unit, for places where an icon names the metric.
    public static func speed(_ kmh: Double?, imperial: Bool, compact: Bool = false) -> String {
        guard let kmh else { return "—" }
        let value = String(format: "%.1f", kmh * (imperial ? 0.621371 : 1))
        return compact ? value : "\(value) \(imperial ? "mph" : "km/h")"
    }
    public static func distance(_ meters: Int?, imperial: Bool, compact: Bool = false) -> String {
        guard let meters else { return "—" }
        let value = String(format: "%.2f", Double(meters) / (imperial ? 1609.344 : 1000))
        return compact ? value : "\(value) \(imperial ? "mi" : "km")"
    }
    /// Compact form omits hours under one hour: 37:32.
    public static func duration(_ seconds: Int?, estimated: Bool = false, compact: Bool = false) -> String {
        guard let seconds else { return "—" }
        let text = compact && seconds < 3600
            ? String(format: "%d:%02d", seconds / 60, seconds % 60)
            : String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        return (estimated ? "~" : "") + text
    }
}
