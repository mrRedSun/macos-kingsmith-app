import SwiftUI
import WalkingPadCore

@main
struct WalkingPadApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PadMenu(model: model, bluetooth: model.bluetooth)
        } label: {
            BarLabel(model: model, bluetooth: model.bluetooth)
        }
        .menuBarExtraStyle(.window)

        Settings { PreferencesView(model: model) }
            .windowResizability(.contentSize)
    }
}

private struct BarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bluetooth: BluetoothController
    var body: some View {
        // The icon stands in when every metric is turned off, so the item never disappears.
        Group {
            if let image = model.barReadings.isEmpty ? nil : BarReadout.image(model.barReadings, stacked: model.barStacked) {
                Image(nsImage: image)
            } else {
                Image(systemName: bluetooth.connected && bluetooth.fresh ? "figure.walk" : "figure.walk.diamond")
            }
        }
        .accessibilityLabel("WalkingPad, \(bluetooth.status), \(model.barTitle)")
    }
}

private struct PadMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bluetooth: BluetoothController
    @State private var showHistory = false
    @State private var contentHeight: CGFloat = 0
    private var controlsEnabled: Bool {
        bluetooth.connected && bluetooth.hasControl && bluetooth.fresh && !bluetooth.busy
    }

    var body: some View {
        VStack(spacing: 20) {
            header
            GlassNavigation(showHistory: $showHistory)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    messages
                    if showHistory { HistoryView(model: model) }
                    else if bluetooth.connected { walkingControls }
                    else { connectionControls }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            // Fits the content, so the popup has no empty band; scrolls past the cap.
            .frame(height: min(max(contentHeight, 1), 460))
            footer
        }
        .padding(22)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.walk")
                .font(.system(size: 23, weight: .medium))
                .frame(width: 42, height: 42)
                .glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(bluetooth.connected ? bluetooth.connectedName ?? "WalkingPad" : "WalkingPad")
                    .font(.system(.headline, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(bluetooth.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if bluetooth.busy || (bluetooth.connecting && !bluetooth.waitingForPad) { ProgressView().controlSize(.mini) }
            SettingsLink {
                Image(systemName: "gearshape").frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Settings")
            .accessibilityLabel("Open settings")
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
        }
    }
    private var statusColor: Color {
        bluetooth.connected ? (bluetooth.fresh ? .green : .orange) : .secondary
    }
    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today").font(.caption).foregroundStyle(.secondary)
                Text(DisplayFormat.distance(model.todayMeters, imperial: model.imperial))
                    .font(.system(.callout, design: .rounded).weight(.medium))
            }
            Spacer()
            if bluetooth.connected {
                Button("Disconnect") { bluetooth.disconnect() }.buttonStyle(.plain).font(.caption)
            }
            Button { model.quit() } label: {
                Image(systemName: "power").frame(width: 26, height: 26)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(model.quitting ? "Saving statistics…" : "Quit WalkingPad")
            .accessibilityLabel("Quit WalkingPad").disabled(model.quitting)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var walkingControls: some View {
        ControlPanel(
            actualKmh: bluetooth.fresh ? bluetooth.telemetry.speedKmh : nil,
            canControl: controlsEnabled,
            canStop: bluetooth.hasControl,
            imperial: model.imperial,
            range: bluetooth.speedRange,
            presets: SpeedControl.presets(model.speedPresets, range: bluetooth.speedRange),
            live: { [bluetooth] in
                .init(moving: bluetooth.fresh && (bluetooth.telemetry.speedKmh ?? 0) > 0, busy: bluetooth.busy)
            },
            start: bluetooth.start, stop: bluetooth.stop, setSpeed: bluetooth.setSpeed
        ) {
            HStack(alignment: .top, spacing: 16) {
                MetricReadout(title: "Distance", value: model.value(.distance, source: "pad"))
                MetricReadout(title: "Steps", value: model.value(.steps, source: "pad").replacingOccurrences(of: " steps", with: ""))
                MetricReadout(title: "Time", value: model.value(.duration, source: "pad"))
            }
        }
        if bluetooth.steppedOffStop {
            Label("Stopped because nobody was walking.", systemImage: "figure.stand").font(.caption)
        }
        if bluetooth.stopQueued {
            Label("Stop queued. Use your remote if needed.", systemImage: "clock").font(.caption)
        }
        Text("Keep the remote nearby. Disconnecting or quitting doesn't stop the belt.")
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var connectionControls: some View {
        VStack(spacing: 13) {
            Image(systemName: bluetooth.connecting ? "antenna.radiowaves.left.and.right" : "figure.walk")
                .font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                .frame(height: 48)
            Text(bluetooth.waitingForPad ? "Waiting for \(bluetooth.connectedName ?? "your pad")"
                 : bluetooth.connecting ? "Connecting to your pad" : bluetooth.scanning ? "Finding your pad" : "Ready for a walk?")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text(bluetooth.waitingForPad ? "It connects as soon as the pad wakes up. Close other walking-pad apps."
                 : "Wake your pad and close other walking-pad apps.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if bluetooth.connecting {
                Button(bluetooth.waitingForPad ? "Stop waiting" : "Cancel connection") { bluetooth.disconnect() }
                    .buttonStyle(.glass)
            } else if bluetooth.scanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Button("Stop search") { bluetooth.stopScan() }.buttonStyle(.glass)
                }
            } else {
                Button("Find walking pad", systemImage: "antenna.radiowaves.left.and.right") { bluetooth.scan() }
                    .buttonStyle(.glassProminent).controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        if !bluetooth.connecting {
            ForEach(bluetooth.devices) { device in
                Button { bluetooth.connect(device) } label: {
                    HStack {
                        Label(device.name, systemImage: "figure.walk")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }.padding(.vertical, 7).frame(maxWidth: .infinity)
                }.buttonStyle(.glass)
            }
        }
    }

    @ViewBuilder private var messages: some View {
        if let message = bluetooth.errorMessage {
            InlineNotice(message: message, symbol: "exclamationmark.triangle") {
                Button("Dismiss") { bluetooth.errorMessage = nil }
            }
        }
        if let message = model.storageError {
            InlineNotice(message: message, symbol: "externaldrive.badge.exclamationmark") {
                Button("Retry saving") { model.retrySaving() }
            }
        }
        if let message = model.exportError {
            InlineNotice(message: message, symbol: "exclamationmark.triangle") {
                Button("Dismiss") { model.exportError = nil }
            }
        }
        if model.quitNeedsConfirmation {
            InlineNotice(message: "Some statistics haven't been saved.", symbol: "exclamationmark.triangle") {
                HStack {
                    Button("Export CSV…") { model.exportCSV() }
                    Button("Cancel") { model.quitNeedsConfirmation = false }
                    Button("Quit anyway", role: .destructive) { model.terminate() }
                }
            }
        }
    }
}
