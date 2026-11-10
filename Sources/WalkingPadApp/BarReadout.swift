import SwiftUI
import AppKit
import WalkingPadCore

/// The menu-bar readout: an icon per metric instead of unit text, optionally
/// stacked two per column.
struct BarReadout: View {
    struct Reading: Identifiable, Equatable {
        let metric: Metric
        let value: String
        var id: Metric { metric }
    }
    let readings: [Reading]
    let stacked: Bool

    var body: some View {
        if stacked && readings.count > 1 {
            HStack(alignment: .center, spacing: 7) {
                ForEach(Array(stride(from: 0, to: readings.count, by: 2)), id: \.self) { index in
                    VStack(alignment: .leading, spacing: -1) {
                        ForEach(readings[index..<min(index + 2, readings.count)]) { row($0, iconWidth: 10) }
                    }
                }
            }
            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
        } else {
            HStack(spacing: 8) {
                ForEach(readings) { row($0, iconWidth: nil) }
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
        }
    }

    private func row(_ reading: Reading, iconWidth: CGFloat?) -> some View {
        HStack(spacing: 2) {
            Image(systemName: reading.metric.symbol)
                .imageScale(.small)
                .frame(width: iconWidth)
            Text(reading.value)
        }
        .fixedSize() // Never truncate a value; the item grows instead.
    }

    /// Menu-bar labels can't lay out stacked views, so the readout is drawn into a
    /// template image that follows the menu bar's light or dark appearance.
    @MainActor static func image(_ readings: [Reading], stacked: Bool) -> NSImage? {
        let renderer = ImageRenderer(content: BarReadout(readings: readings, stacked: stacked)
            .foregroundStyle(.black).frame(height: 22).fixedSize())
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}
