import Foundation

/// FTMS allows one procedure at a time. Stop has priority over future commands
/// and remains available without fresh telemetry. Start/speed are never retried.
public struct ControlQueue: Sendable {
    public private(set) var pendingOpcode: UInt8?
    public private(set) var stopQueued = false
    public var busy: Bool { pendingOpcode != nil }
    public init() {}

    public enum Rejection: LocalizedError {
        case noControl, stale, busy, invalid
        public var errorDescription: String? {
            switch self {
            case .noControl: "The pad has not granted control. Reconnect and close other apps."
            case .stale: "Telemetry is stale. Only Stop is available."
            case .busy: "A command is awaiting acknowledgement. Stop can still be queued."
            case .invalid: "Invalid control command."
            }
        }
    }

    /// Returns bytes to send now, or nil if Stop was queued behind an active procedure.
    public mutating func request(_ data: Data, hasControl: Bool, fresh: Bool) throws -> Data? {
        guard let opcode = data.first else { throw Rejection.invalid }
        guard hasControl || data == FTMS.requestControl else { throw Rejection.noControl }
        if data == FTMS.stop {
            if busy {
                if pendingOpcode != 8 { stopQueued = true }
                return nil
            }
        } else {
            guard !busy else { throw Rejection.busy }
            guard data == FTMS.requestControl || fresh else { throw Rejection.stale }
        }
        pendingOpcode = opcode
        return data
    }

    public mutating func complete(opcode: UInt8, hasControl: Bool) -> Data? {
        guard opcode == pendingOpcode else { return nil }
        pendingOpcode = nil
        return drainStop(hasControl: hasControl)
    }

    /// A queued Stop gets one best-effort attempt even if the preceding command
    /// times out. It is never an emergency-stop guarantee.
    public mutating func timeout(hasControl: Bool) -> Data? {
        pendingOpcode = nil
        return drainStop(hasControl: hasControl)
    }

    public mutating func reset() { self = Self() }

    private mutating func drainStop(hasControl: Bool) -> Data? {
        let shouldStop = stopQueued && hasControl
        stopQueued = false
        if shouldStop { pendingOpcode = 8; return FTMS.stop }
        return nil
    }
}
