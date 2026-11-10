import SwiftUI
import WalkingPadCore

struct PreferencesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Menu bar").font(.system(.title2, design: .rounded).weight(.semibold))
                        Text("Choose what stays visible while you walk.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "figure.walk").font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                }
                StatusItemPreview(model: model, bluetooth: model.bluetooth)

                VStack(spacing: 0) {
                    HStack {
                        Text("Totals from").font(.callout)
                        Spacer()
                        Picker("Counter source", selection: $model.barSource) {
                            Text("This session").tag("session")
                            Text("Today").tag("today")
                            Text("Pad totals").tag("pad")
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }.frame(minHeight: 48)
                    Divider()
                    Toggle("Two rows", isOn: $model.barStacked)
                        .toggleStyle(.switch).controlSize(.small)
                        .frame(minHeight: 44)
                    Divider()
                    MetricPreferenceRows(visible: $model.barMetrics)
                }
                .padding(.horizontal, 16)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))

                Text("Use the reorder menu beside an enabled item to change its position. Each value shows its icon instead of a unit. Two rows stack them in pairs, in this order. Turn every item off for a single icon.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, -12)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Speed presets").font(.headline)
                    SpeedPresetRows(presets: $model.speedPresets, imperial: model.imperial,
                                    range: model.bluetooth.speedRange)
                        .padding(.horizontal, 16)
                        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))
                    Text("Presets appear in the popup and change speed while the belt is moving.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Connection").font(.headline)
                    Toggle("Connect automatically", isOn: $model.autoConnect)
                        .toggleStyle(.switch).controlSize(.small)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 16)
                        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))
                    Text("Reconnects to the last pad whenever it wakes up. Disconnect in the popup pauses this until you connect again.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Display").font(.headline)
                    VStack(alignment: .leading, spacing: 0) {
                        Toggle("Miles and mph", isOn: $model.imperial)
                            .frame(minHeight: 44)
                        Divider()
                        Toggle("FTMS step extension", isOn: $model.stepExtension)
                            .frame(minHeight: 44)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    .padding(.horizontal, 16)
                    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))
                    Text("Standard WalkingPad steps are automatic. The extension is only for FTMS firmware. Speed controls always use km/h.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    DisclosureGroup("About your statistics") {
                        Text("Activity stays on this Mac in SQLite. Only changes observed while connected are counted. Sessions split at midnight. A ~ marks estimated time. Steps may be partial if decoding started later. Compare firmware-specific FTMS steps with the pad before relying on them.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 7)
                    }.font(.callout)
                    Spacer(minLength: 12)
                    Button("Export CSV…") { model.exportCSV() }.buttonStyle(.glass)
                }
                if let error = model.exportError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                }
            }
            .padding(24)
        }
        .frame(width: 500, height: 650)
        .background(.regularMaterial)
    }
}

/// One ForEach owns all row identities. No flattened Form sections containing
/// duplicate metric IDs, and no separate list that can replace the toggles.
struct MetricPreferenceRows: View {
    @Binding var visible: [String]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(MetricPreferences.rows(visible)) { metric in
                HStack(spacing: 12) {
                    Image(systemName: metric.symbol).foregroundStyle(.secondary).frame(width: 18)
                    Text(metric.title).font(.callout)
                    Spacer()
                    if visible.contains(metric.rawValue) {
                        Menu {
                            Button("Move earlier", systemImage: "arrow.up") { move(metric, by: -1) }
                                .disabled(visible.first == metric.rawValue)
                            Button("Move later", systemImage: "arrow.down") { move(metric, by: 1) }
                                .disabled(visible.last == metric.rawValue)
                        } label: {
                            Image(systemName: "arrow.up.arrow.down").frame(width: 18)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Reorder \(metric.title.lowercased())")
                        .help("Reorder \(metric.title.lowercased())")
                    }
                    Toggle(metric.title, isOn: Binding(
                        get: { visible.contains(metric.rawValue) },
                        set: { enabled in
                            var names = MetricPreferences.enabled(visible).map(\.rawValue)
                            if enabled { names.append(metric.rawValue) }
                            else { names.removeAll { $0 == metric.rawValue } }
                            visible = MetricPreferences.enabled(names).map(\.rawValue)
                        }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("Show \(metric.title.lowercased()) in menu bar")
                    .accessibilityIdentifier("metric-toggle-\(metric.rawValue)")
                }
                .frame(minHeight: 44)
                if metric != MetricPreferences.rows(visible).last { Divider() }
            }
        }
    }
    private func move(_ metric: Metric, by offset: Int) {
        guard let index = visible.firstIndex(of: metric.rawValue), visible.indices.contains(index + offset) else { return }
        visible.swapAt(index, index + offset)
    }
}

struct SpeedPresetRows: View {
    @Binding var presets: [Double]
    let imperial: Bool
    let range: FTMS.SpeedRange
    var body: some View {
        VStack(spacing: 0) {
            ForEach(presets.indices, id: \.self) { index in
                HStack(spacing: 12) {
                    Text("Preset \(index + 1)").font(.callout)
                    Spacer()
                    Text("\(SpeedControl.label(presets[index], imperial: imperial)) \(imperial ? "mph" : "km/h")")
                        .font(.callout.weight(.medium)).monospacedDigit()
                    Stepper("Preset \(index + 1)") {
                        presets[index] = SpeedControl.adjust(presets[index], by: 1, imperial: imperial, range: range)
                    } onDecrement: {
                        presets[index] = SpeedControl.adjust(presets[index], by: -1, imperial: imperial, range: range)
                    }
                    .labelsHidden()
                }
                .frame(minHeight: 44)
                if index < presets.count - 1 { Divider() }
            }
        }
    }
}

private struct StatusItemPreview: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bluetooth: BluetoothController
    var body: some View {
        HStack {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Group {
                if model.barReadings.isEmpty { Image(systemName: "figure.walk") }
                else { BarReadout(readings: model.barReadings, stacked: model.barStacked).frame(height: 22) }
            }.padding(.horizontal, 13).padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

// Release builds skip previews: the Command Line Tools lack the preview macro plugin.
#if DEBUG
#Preview("Four unique metric rows") {
    @Previewable @State var visible = ["speed", "steps", "distance", "duration"]
    MetricPreferenceRows(visible: $visible)
        .padding(.horizontal, 16)
        .frame(width: 452)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))
        .padding(24)
}
#endif
