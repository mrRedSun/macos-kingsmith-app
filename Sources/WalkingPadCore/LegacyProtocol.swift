import Foundation

/// KingSmith FE00/FFF0 framing. Commands are F7 A2, status replies F8 A2.
/// The stored-walk query is F7 A7 and its reply F8 A7.
/// Counter integers in this protocol are big-endian, unlike FTMS.
public enum LegacyProtocol {
    public enum Failure: Error, Equatable, LocalizedError {
        case invalidFrame, invalidChecksum
        public var errorDescription: String? {
            switch self {
            case .invalidFrame: "Invalid WalkingPad status frame."
            case .invalidChecksum: "WalkingPad status checksum did not match."
            }
        }
    }

    public enum Command: Equatable, Sendable {
        case statistics, history, manualMode, start, stop, speed(Double)
        /// Queries never move the belt. They are dropped rather than queued behind motor commands.
        public var isMotorCommand: Bool { self != .statistics && self != .history }
        /// All frames verified on KS-BDC2. Speed is opcode 1, Stop is speed 0, and
        /// Start is ignored unless the pad is in manual mode (opcode 2, mode 1).
        public func encoded() throws -> Data {
            switch self {
            case .statistics: return frame([0, 0])
            case .history: return frame([0xAA, 0xFF], header: 0xA7)
            case .manualMode: return frame([2, 1])
            case .start: return frame([4, 1])
            case .stop: return frame([1, 0])
            case .speed(let kmh):
                // Share the range/increment validation, never silently round unsafe input.
                _ = try FTMS.setSpeed(kmh)
                return frame([1, UInt8((kmh * 10).rounded())])
            }
        }
    }

    private static func frame(_ body: [UInt8], header: UInt8 = 0xA2) -> Data {
        let payload = [header] + body
        return Data([0xF7] + payload + [payload.reduce(0, &+), 0xFD])
    }

    /// The pad's summary of its latest walk. KS-BDC2 returns zeros during a walk and the
    /// finished walk after Stop, on every query. (The reference library's `AA 00` variant
    /// appears to mark it read, so this client never sends it.) The ID is the walk's start on the pad's own clock, so
    /// it stays the same when a stopped walk is resumed.
    public struct Record: Equatable, Sendable {
        public var walkID: UInt32
        public var seconds: Int
        public var distanceMeters: Int
        public var steps: Int
        public init(walkID: UInt32, seconds: Int, distanceMeters: Int, steps: Int) {
            self.walkID = walkID; self.seconds = seconds; self.distanceMeters = distanceMeters; self.steps = steps
        }
    }

    public enum Frame: Equatable, Sendable {
        case status(FTMS.Telemetry)
        /// nil when the pad has no unread walk.
        case record(Record?)
    }

    public static func decodeFrame(_ data: Data) throws -> Frame {
        let bytes = Array(data)
        guard bytes.count >= 2, bytes[1] == 0xA7 else { return .status(try decode(data)) }
        guard bytes.count == 20, bytes[0] == 0xF8, bytes.last == 0xFD else { throw Failure.invalidFrame }
        guard bytes[1..<18].reduce(UInt8(0), &+) == bytes[18] else { throw Failure.invalidChecksum }
        func word(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        let id = bytes[2..<6].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let record = Record(walkID: id, seconds: word(6), distanceMeters: word(8) * 10, steps: word(10))
        return .record(id == 0 && record.seconds == 0 ? nil : record)
    }

    public static func decode(_ data: Data) throws -> FTMS.Telemetry {
        let bytes = Array(data)
        guard bytes.count >= 16, bytes.count <= 64,
              bytes[0] == 0xF8 || bytes[0] == 0xF7,
              bytes[1] == 0xA2, bytes.last == 0xFD else { throw Failure.invalidFrame }
        guard bytes[1..<(bytes.count - 2)].reduce(UInt8(0), &+) == bytes[bytes.count - 2] else {
            throw Failure.invalidChecksum
        }
        func counter(_ offset: Int) -> Int {
            (Int(bytes[offset]) << 16) | (Int(bytes[offset + 1]) << 8) | Int(bytes[offset + 2])
        }
        return .init(speedKmh: Double(bytes[3]) / 10, distanceMeters: counter(8) * 10,
                     elapsedSeconds: counter(5), steps: counter(11))
    }

    /// Reassembles split/coalesced BLE notifications. The bounded buffer drops
    /// noise and malformed frames; no unverified counters reach persistence.
    public struct StreamDecoder: Sendable {
        private var buffer: [UInt8] = []
        public init() {}
        public mutating func append(_ data: Data) -> [Frame] {
            // BLE values are bounded by ATT MTU, but cap even synthetic input.
            buffer.append(contentsOf: data.suffix(512))
            var updates: [Frame] = []
            while buffer.count >= 2 {
                guard (buffer[0] == 0xF8 || buffer[0] == 0xF7), buffer[1] == 0xA2 || buffer[1] == 0xA7 else {
                    buffer.removeFirst(); continue
                }
                var consumed = false
                if buffer.count >= 16 {
                    for end in 15..<min(buffer.count, 64) where buffer[end] == 0xFD {
                        if let sample = try? LegacyProtocol.decodeFrame(Data(buffer[0...end])) {
                            updates.append(sample)
                            buffer.removeFirst(end + 1)
                            consumed = true
                            break
                        }
                    }
                }
                if consumed { continue }
                // Skip corrupt headers only when a complete, checksum-verified
                // replacement exists. Try every candidate, not just the first
                // header-like pair in a corrupt payload.
                if buffer.count > 2, let next = (2..<(buffer.count - 1)).first(where: { index in
                    guard (buffer[index] == 0xF8 || buffer[index] == 0xF7),
                          buffer[index + 1] == 0xA2 || buffer[index + 1] == 0xA7,
                          buffer.count - index >= 16 else { return false }
                    return (16...min(buffer.count - index, 64)).contains { length in
                        (try? LegacyProtocol.decodeFrame(Data(buffer[index..<(index + length)]))) != nil
                    }
                }) {
                    buffer.removeFirst(next)
                    continue
                }
                if buffer.count >= 64 { buffer.removeFirst(); continue }
                break
            }
            return updates
        }
    }
}

/// Serializes legacy GATT writes. Polls never queue up behind motor commands;
/// Stop replaces any unsent command and follows the current write first.
/// Start expands to manual mode followed by Start.
public struct LegacyWriteQueue: Sendable {
    public private(set) var inFlight: LegacyProtocol.Command?
    public private(set) var pending: [LegacyProtocol.Command] = []
    public var busy: Bool { inFlight?.isMotorCommand == true || !pending.isEmpty }
    public var stopQueued: Bool { pending == [.stop] }
    public init() {}

    public mutating func request(_ command: LegacyProtocol.Command) throws -> LegacyProtocol.Command? {
        let sequence: [LegacyProtocol.Command] = command == .start ? [.manualMode, .start] : [command]
        if inFlight == nil {
            inFlight = sequence[0]
            pending = Array(sequence.dropFirst())
            return inFlight
        }
        if !command.isMotorCommand { return nil }
        if command == .stop {
            pending = inFlight == .stop ? [] : [.stop]
            return nil
        }
        guard inFlight?.isMotorCommand == false, pending.isEmpty else { throw ControlQueue.Rejection.busy }
        pending = sequence
        return nil
    }
    public mutating func complete() -> LegacyProtocol.Command? {
        inFlight = pending.isEmpty ? nil : pending.removeFirst()
        return inFlight
    }
    /// After a lost write only a queued Stop is attempted; Start and speed are never retried.
    public mutating func timeout() -> LegacyProtocol.Command? {
        inFlight = pending.contains(.stop) ? .stop : nil
        pending = []
        return inFlight
    }
    public mutating func reset() { self = Self() }
}
