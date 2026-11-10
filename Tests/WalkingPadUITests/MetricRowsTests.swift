import AppKit
import SwiftUI
import Testing
@testable import WalkingPadApp

struct MetricRowsTests {
    @Test @MainActor func metricRowsRenderAtFourRowHeightInBothAppearances() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/design-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let content = MetricPreferenceRows(visible: .constant(["speed", "steps", "distance", "duration"]))
                .padding(.horizontal, 16)
                .frame(width: 452)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))
                .padding(24)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            // Four 44-point rows plus three dividers and outer 48-point padding.
            // The old duplicated layout would be over 350 points tall.
            #expect(host.frame.width == 500)
            #expect(host.frame.height >= 224 && host.frame.height < 230)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(scheme == .light ? "metrics-light.png" : "metrics-dark.png"))
        }
    }
}
