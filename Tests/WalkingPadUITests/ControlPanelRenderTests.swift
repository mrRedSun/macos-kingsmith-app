import AppKit
import SwiftUI
import Testing
import WalkingPadCore
@testable import WalkingPadApp

/// Visual review of the belt controls: `WALKINGPAD_SNAPSHOTS=1 swift test --filter ControlPanelRender`.
/// Liquid Glass only draws in an on-screen window, so this briefly shows one and captures it.
@MainActor
struct ControlPanelRenderTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["WALKINGPAD_SNAPSHOTS"] != nil

    private func panel(actual: Double?) -> some View {
        ControlPanel(actualKmh: actual, canControl: true, canStop: true, imperial: false,
                     range: .conservative, presets: SpeedControl.defaultPresetsKmh,
                     live: { .init(moving: false, busy: false) },
                     start: {}, stop: {}, setSpeed: { _ in }) {
            HStack(alignment: .top, spacing: 16) {
                MetricReadout(title: "Distance", value: "0.42 km")
                MetricReadout(title: "Steps", value: "618")
                MetricReadout(title: "Time", value: "0:07:12")
            }
        }
        .frame(width: 336)
    }

    @Test(.enabled(if: enabled)) func rendersEveryBeltStateInBothAppearances() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/design-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let content = HStack(alignment: .top, spacing: 44) {
                panel(actual: 0)
                panel(actual: nil)
                panel(actual: 3.0)
                SpeedPresetRows(presets: .constant(SpeedControl.defaultPresetsKmh), imperial: false, range: .conservative)
                    .padding(.horizontal, 16)
                    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))
                    .frame(width: 300)
            }
            .padding(22)
            // The test process is never the active app; draw controls as the popup would.
            .environment(\.controlActiveState, .key)
            let host = NSHostingView(rootView: content)
            host.setFrameSize(host.fittingSize)
            let window = KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.backgroundColor = dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.96, alpha: 1)
            window.contentView = host
            window.level = .floating
            window.center()
            // Prominent and tinted buttons only show their color in the active key window.
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(900))
            let image = try #require(Self.capture(window.windowNumber))
            window.orderOut(nil)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(dark ? "controls-dark.png" : "controls-light.png"))
        }
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    /// CGWindowListCreateImage is hidden from the macOS 26 SDK but still captures
    /// this process's own windows without Screen Recording permission.
    private static func capture(_ windowNumber: Int) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Capture.self)
        // Including-window option = 1 << 3; ignore framing = 1 << 0, best resolution = 1 << 3.
        return create(.null, 1 << 3, UInt32(windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue()
    }
}
