import Foundation

/// Bluetooth Fitness Machine Service. All wire integers are little-endian.
public enum FTMS {
    public static let service = "1826"
    public static let treadmillData = "2ACD"
    public static let controlPoint = "2AD9"
    public static let speedRange = "2AD4"

    public enum Failure: Error, Equatable, LocalizedError {
        case truncated, unsupportedFlags, invalidSpeed, invalidResponse
        public var errorDescription: String? {
            switch self {
            case .truncated: "Incomplete treadmill data packet."
            case .unsupportedFlags: "Unsupported treadmill data flags."
            case .invalidSpeed: "Speed is outside the supported range or increment."
            case .invalidResponse: "Invalid control-point response."
            }
        }
    }

    public struct Telemetry: Equatable, Sendable {
        public var speedKmh: Double?
        public var distanceMeters: Int?
        public var elapsedSeconds: Int?
        public var steps: Int?
        public init(speedKmh: Double? = nil, distanceMeters: Int? = nil,
                    elapsedSeconds: Int? = nil, steps: Int? = nil) {
            self.speedKmh = speedKmh
            self.distanceMeters = distanceMeters
            self.elapsedSeconds = elapsedSeconds
            self.steps = steps
        }
        public mutating func merge(_ update: Self) {
            if let value = update.speedKmh { speedKmh = value }
            if let value = update.distanceMeters { distanceMeters = value }
            if let value = update.elapsedSeconds { elapsedSeconds = value }
            if let value = update.steps { steps = value }
        }
    }

    public struct SpeedRange: Equatable, Sendable {
        public var minimum: Double
        public var maximum: Double
        public var increment: Double
        public static let conservative = Self(minimum: 0.5, maximum: 6, increment: 0.1)
        public init(minimum: Double, maximum: Double, increment: Double) {
            self.minimum = minimum; self.maximum = maximum; self.increment = increment
        }
        public init(data: Data) throws {
            var reader = Reader(data)
            let low = try reader.integer(2)
            let high = try reader.integer(2)
            let step = try reader.integer(2)
            guard high > 0, high >= low, step > 0 else { throw Failure.invalidSpeed }
            self.init(minimum: Double(low) / 100, maximum: Double(high) / 100,
                      increment: Double(step) / 100)
        }
    }

    /// Parses the standard optional fields before considering the opt-in C2 suffix.
    /// Unknown suffixes are never guessed to be step counts.
    public static func decode(_ data: Data, c2StepExtension: Bool = false) throws -> Telemetry {
        var reader = Reader(data)
        let flags = try reader.integer(2)
        guard flags & 0xE000 == 0 else { throw Failure.unsupportedFlags }
        var result = Telemetry()
        // Bit 0 means "More Data": instantaneous speed is absent in this fragment.
        if flags & 1 == 0 { result.speedKmh = Double(try reader.integer(2)) / 100 }
        if flags & (1 << 1) != 0 { try reader.skip(2) } // average speed
        if flags & (1 << 2) != 0 { result.distanceMeters = try reader.integer(3) }
        if flags & (1 << 3) != 0 { try reader.skip(4) } // inclination, ramp angle
        if flags & (1 << 4) != 0 { try reader.skip(4) } // positive and negative elevation
        if flags & (1 << 5) != 0 { try reader.skip(1) }
        if flags & (1 << 6) != 0 { try reader.skip(1) }
        if flags & (1 << 7) != 0 { try reader.skip(5) } // total, hourly, per-minute energy
        if flags & (1 << 8) != 0 { try reader.skip(1) }
        if flags & (1 << 9) != 0 { try reader.skip(1) }
        if flags & (1 << 10) != 0 { result.elapsedSeconds = try reader.integer(2) }
        if flags & (1 << 11) != 0 { try reader.skip(2) } // remaining time is NOT steps
        if flags & (1 << 12) != 0 { try reader.skip(4) } // force and power
        if c2StepExtension && reader.remaining == 2 { result.steps = try reader.integer(2) }
        return result
    }

    public static let requestControl = Data([0x00])
    public static let start = Data([0x07])
    public static let stop = Data([0x08, 0x01])

    public static func setSpeed(_ kmh: Double, range: SpeedRange = .conservative) throws -> Data {
        guard kmh.isFinite, range.increment.isFinite, range.increment > 0,
              kmh >= range.minimum, kmh <= range.maximum else { throw Failure.invalidSpeed }
        let units = kmh * 100
        let ticks = (kmh - range.minimum) / range.increment
        guard units <= Double(UInt16.max), abs(ticks - ticks.rounded()) < 0.001 else {
            throw Failure.invalidSpeed
        }
        let value = UInt16(units.rounded())
        return Data([0x02, UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    public struct Response: Equatable, Sendable {
        public let opcode: UInt8
        public let result: UInt8
        public var succeeded: Bool { result == 1 }
        public var message: String {
            switch result {
            case 1: "Command accepted"
            case 2: "Command not supported by this pad"
            case 3: "Pad rejected the command parameters"
            case 4: "Pad could not complete the command"
            case 5: "Control denied. Disconnect other treadmill apps and reconnect."
            default: "Unknown control response: \(result)"
            }
        }
        public init(_ data: Data) throws {
            let bytes = [UInt8](data)
            guard bytes.count == 3, bytes[0] == 0x80 else { throw Failure.invalidResponse }
            opcode = bytes[1]; result = bytes[2]
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        init(_ data: Data) { bytes = Array(data) }
        var remaining: Int { bytes.count - offset }
        mutating func integer(_ count: Int) throws -> Int {
            guard remaining >= count else { throw Failure.truncated }
            var value = 0
            for index in 0..<count { value |= Int(bytes[offset + index]) << (8 * index) }
            offset += count
            return value
        }
        mutating func skip(_ count: Int) throws {
            guard remaining >= count else { throw Failure.truncated }
            offset += count
        }
    }
}
