/// A single, stable row per metric. Enabled metrics retain their menu-bar order;
/// disabled metrics follow them so every toggle remains reachable.
public enum MetricPreferences {
    public static func enabled(_ names: [String]) -> [Metric] {
        var seen = Set<Metric>()
        return names.compactMap(Metric.init(rawValue:)).filter { seen.insert($0).inserted }
    }
    public static func rows(_ names: [String]) -> [Metric] {
        let selected = enabled(names)
        return selected + Metric.allCases.filter { !selected.contains($0) }
    }
}
