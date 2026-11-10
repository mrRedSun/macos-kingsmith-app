import Foundation
import Testing
import WalkingPadCore
@testable import WalkingPadApp

/// Opt-in check against a real pad: `WALKINGPAD_HARDWARE=KS-BDC2 swift test --filter Hardware`.
/// Read only. It never calls start(), stop(), or setSpeed(); the controller's only
/// automatic write is the legacy status query.
@MainActor @Suite(.serialized)
struct HardwareConnectionTests {
    nonisolated static let target = ProcessInfo.processInfo.environment["WALKINGPAD_HARDWARE"]

    @Test(.enabled(if: target != nil), .timeLimit(.minutes(1)))
    func connectsReadOnlyAndReceivesPolledTelemetry() async throws {
        let target = try #require(Self.target)
        let bluetooth = BluetoothController()
        var updates: [FTMS.Telemetry] = []
        bluetooth.onTelemetry = { updates.append($0) }

        try await waitUntil(10) { bluetooth.scan(); return bluetooth.scanning }
        try await waitUntil(15) { bluetooth.devices.contains { $0.name == target } }
        // Unnamed nearby phones and headphones must not flood the list.
        #expect(!bluetooth.devices.contains { $0.name == "Walking pad" && $0.peripheral.name == nil })
        print("Listed devices:", bluetooth.devices.map(\.name))

        let device = try #require(bluetooth.devices.first { $0.name == target })
        bluetooth.connect(device)
        try await waitUntil(20) { bluetooth.connected && bluetooth.fresh }
        print("Profile:", bluetooth.profile?.title ?? "nil", "status:", bluetooth.status, "telemetry:", bluetooth.telemetry)
        #expect(bluetooth.hasControl)
        #expect(bluetooth.errorMessage == nil)

        let initial = updates.count
        try await waitUntil(10) { updates.count >= initial + 2 }
        #expect(bluetooth.telemetry.elapsedSeconds != nil && bluetooth.telemetry.distanceMeters != nil)
        print("Polled samples:", updates.count)
        bluetooth.disconnect()
    }

    /// Moves the belt. Run only with nobody on the pad:
    /// `WALKINGPAD_HARDWARE=KS-BDC2 WALKINGPAD_MOTOR=1 swift test --filter Hardware`.
    @Test(.enabled(if: target != nil && ProcessInfo.processInfo.environment["WALKINGPAD_MOTOR"] != nil),
          .timeLimit(.minutes(1)))
    func startsChangesSpeedAndStopsThroughTheApp() async throws {
        let target = try #require(Self.target)
        let bluetooth = BluetoothController()
        try await waitUntil(10) { bluetooth.scan(); return bluetooth.scanning }
        try await waitUntil(15) { bluetooth.devices.contains { $0.name == target } }
        bluetooth.connect(try #require(bluetooth.devices.first { $0.name == target }))
        defer { bluetooth.stop() }
        let state = { "status=\(bluetooth.status) busy=\(bluetooth.busy) error=\(bluetooth.errorMessage ?? "-") \(bluetooth.telemetry)" }
        try await waitUntil(20, state) { bluetooth.connected && bluetooth.fresh && bluetooth.hasControl }

        print("Connected; sending Start")
        bluetooth.start()
        try await waitUntil(15, state) { (bluetooth.telemetry.speedKmh ?? 0) > 0 }
        print("Moving at", bluetooth.telemetry.speedKmh ?? 0)
        try await Task.sleep(for: .seconds(3))
        bluetooth.setSpeed(2.5)
        try await waitUntil(10, state) { abs((bluetooth.telemetry.speedKmh ?? 0) - 2.5) < 0.05 }
        print("Changed to", bluetooth.telemetry.speedKmh ?? 0)
        bluetooth.stop()
        try await waitUntil(15, state) { bluetooth.telemetry.speedKmh == 0 }
        print("Stopped")
        #expect(bluetooth.errorMessage == nil)
        bluetooth.disconnect()
    }

    private func waitUntil(_ seconds: Double, _ state: () -> String = { "" }, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { Issue.record("Timed out after \(seconds)s. \(state())"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
