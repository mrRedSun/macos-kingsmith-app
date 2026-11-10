import Foundation

/// Speed values shown to the user versus sent to the pad. Commands are always km/h
/// on the pad's increment grid; buttons step in half units of the display unit.
public enum SpeedControl {
    public static let defaultPresetsKmh: [Double] = [2, 3, 4, 5]
    public static let stepSize = 0.5
    private static let kmPerMile = 1.609344

    public static func display(_ kmh: Double, imperial: Bool) -> Double {
        imperial ? kmh / kmPerMile : kmh
    }

    public static func label(_ kmh: Double, imperial: Bool) -> String {
        String(format: "%.1f", display(kmh, imperial: imperial))
    }

    /// Clamps into the range and snaps onto the increment grid that starts at the minimum.
    public static func snap(_ kmh: Double, range: FTMS.SpeedRange) -> Double {
        let clamped = min(max(kmh, range.minimum), range.maximum)
        let ticks = ((clamped - range.minimum) / range.increment).rounded()
        var value = range.minimum + ticks * range.increment
        if value > range.maximum + 1e-9 { value -= range.increment }
        return (value * 100).rounded() / 100
    }

    /// Moves to the next half-unit mark in the display unit, so 3.3 goes up to 3.5, not 3.8.
    public static func adjust(_ kmh: Double, by steps: Int, imperial: Bool, range: FTMS.SpeedRange) -> Double {
        // Tolerance absorbs increment snapping, e.g. 2.0 mph is sent as 3.2 km/h (1.99 mph).
        let marks = display(kmh, imperial: imperial) / stepSize
        let base = steps > 0 ? (marks + 0.1).rounded(.down) : (marks - 0.1).rounded(.up)
        let target = (base + Double(steps)) * stepSize
        return snap(imperial ? target * kmPerMile : target, range: range)
    }

    /// Saved presets, made valid for this pad. Invalid saved values fall back to defaults.
    public static func presets(_ saved: [Double]?, range: FTMS.SpeedRange) -> [Double] {
        let values = saved?.filter(\.isFinite).prefix(4) ?? []
        let source = values.count == 4 ? Array(values) : defaultPresetsKmh
        return source.map { snap($0, range: range) }
    }
}
