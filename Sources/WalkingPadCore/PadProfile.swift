import Foundation

public enum PadProfile: String, Equatable, Sendable {
    case ftms, fe00, fff0

    public static let discoveryServices = ["1826", "FE00", "FFF0"]

    public static func detect(services: [String]) -> Self? {
        let identifiers = Set(services.map(canonical))
        if identifiers.contains("1826") { return .ftms }
        if identifiers.contains("FE00") { return .fe00 }
        if identifiers.contains("FFF0") { return .fff0 }
        return nil
    }

    /// Unnamed advertisers only qualify by service. Never invent a name to match on:
    /// phones and headphones rotate addresses, which would list them endlessly.
    public static func isCandidate(name: String?, services: [String]) -> Bool {
        if detect(services: services) != nil { return true }
        guard let lower = name?.lowercased() else { return false }
        return lower.hasPrefix("walking") || lower.hasPrefix("ks-")
    }

    public var service: String {
        switch self { case .ftms: "1826"; case .fe00: "FE00"; case .fff0: "FFF0" }
    }
    /// Expected roles. FE00 is verified on KS-BDC2. Legacy roles are confirmed
    /// from characteristic properties at connection time.
    public var write: String {
        switch self { case .ftms: "2AD9"; case .fe00: "FE02"; case .fff0: "FFF2" }
    }
    public var notify: String {
        switch self { case .ftms: "2ACD"; case .fe00: "FE01"; case .fff0: "FFF1" }
    }
    public var title: String { self == .ftms ? "FTMS" : "WalkingPad \(service)" }

    private static func canonical(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        let suffix = "-0000-1000-8000-00805F9B34FB"
        if upper.hasPrefix("0000"), upper.hasSuffix(suffix), upper.count == 36 {
            return String(upper.dropFirst(4).prefix(4))
        }
        return upper
    }
}
