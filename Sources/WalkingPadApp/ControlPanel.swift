import SwiftUI
import WalkingPadCore

/// Belt controls. Speed changes are only offered while the belt moves: on A1-style
/// pads "speed 0" is Stop, so a speed command could otherwise start the belt.
struct ControlPanel<Metrics: View>: View {
    struct Live { var moving: Bool; var busy: Bool }

    let actualKmh: Double?
    let canControl: Bool
    let canStop: Bool
    let imperial: Bool
    let range: FTMS.SpeedRange
    let presets: [Double]
    /// Read at send time, so a debounced change never fires after the belt stopped.
    let live: () -> Live
    let start: () -> Void
    let stop: () -> Void
    let setSpeed: (Double) -> Void
    let metrics: Metrics

    @State private var starting = false
    @State private var target: Double?
    @State private var pending: Task<Void, Never>?

    init(actualKmh: Double?, canControl: Bool, canStop: Bool, imperial: Bool, range: FTMS.SpeedRange,
         presets: [Double], live: @escaping () -> Live, start: @escaping () -> Void,
         stop: @escaping () -> Void, setSpeed: @escaping (Double) -> Void,
         @ViewBuilder metrics: () -> Metrics) {
        self.actualKmh = actualKmh; self.canControl = canControl; self.canStop = canStop
        self.imperial = imperial; self.range = range; self.presets = presets; self.live = live
        self.start = start; self.stop = stop; self.setSpeed = setSpeed; self.metrics = metrics()
    }

    private var moving: Bool { (actualKmh ?? 0) > 0 }
    private var speedEnabled: Bool { canControl && moving }
    /// What the step buttons and preset highlight work from: the pending target, else the belt.
    private var workingKmh: Double? { target ?? (moving ? actualKmh : nil) }
    private var unit: String { imperial ? "mph" : "km/h" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            speedRow
            metrics
            Divider()
            presetRow
            beltButtons
        }
        .animation(.snappy(duration: 0.2), value: moving)
        .onChange(of: actualKmh) { _, actual in
            guard let actual, actual > 0 else { cancelPending(); target = nil; return }
            starting = false
            if let target, abs(actual - target) < 0.05 { self.target = nil }
        }
        .onChange(of: canControl) { _, can in if !can { starting = false; cancelPending() } }
        .task(id: starting) {
            // The pad takes a few seconds to spin up; give up waiting if it never reports motion.
            guard starting else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { starting = false }
        }
    }

    /// The belt's real speed is the hero. A pending change shows underneath until the belt gets there.
    private var speedRow: some View {
        HStack {
            stepButton(-1, symbol: "minus", name: "Slower", key: .downArrow)
            Spacer(minLength: 8)
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(actualKmh.map { SpeedControl.label($0, imperial: imperial) } ?? "—")
                        .font(.system(size: 52, weight: .medium, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                    Text(unit).font(.callout).foregroundStyle(.secondary)
                }
                Group {
                    if let target {
                        Text("Changing to \(SpeedControl.label(target, imperial: imperial)) \(unit)")
                            .foregroundStyle(.tint)
                    } else {
                        Text(actualKmh == nil ? "Waiting for the pad" : moving ? "Current speed" : "Belt stopped")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption).contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            stepButton(1, symbol: "plus", name: "Faster", key: .upArrow)
        }
        .animation(.snappy(duration: 0.25), value: actualKmh)
        .animation(.snappy(duration: 0.2), value: target)
    }

    private func stepButton(_ steps: Int, symbol: String, name: String, key: KeyEquivalent) -> some View {
        let base = workingKmh ?? range.minimum
        let next = SpeedControl.adjust(base, by: steps, imperial: imperial, range: range)
        return Button { change(to: next, delay: .milliseconds(450)) } label: {
            Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 34, height: 34)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle)
        .disabled(!speedEnabled || abs(next - base) < 0.01)
        .keyboardShortcut(key, modifiers: [])
        .help("\(name) (\(steps > 0 ? "↑" : "↓"))")
        .accessibilityLabel(name)
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Array(presets.enumerated()), id: \.offset) { _, kmh in
                        let selected = workingKmh.map { abs($0 - kmh) < 0.05 } ?? false
                        Button { change(to: kmh, delay: .zero) } label: {
                            Text(SpeedControl.label(kmh, imperial: imperial))
                                .font(.callout.weight(selected ? .semibold : .regular)).monospacedDigit()
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(selected ? Color.accentColor.opacity(0.3) : .clear).interactive(),
                                     in: .capsule)
                        .disabled(!speedEnabled)
                        .accessibilityLabel("Set speed to \(SpeedControl.label(kmh, imperial: imperial)) \(unit)")
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
            }
            if canControl && !moving {
                Text("Speed controls unlock once the belt is moving.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// One primary action for the belt's state. If the state is unknown, Stop is offered
    /// alongside Start, because stopping is the safe choice.
    @ViewBuilder private var beltButtons: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if moving {
                    Button {
                        cancelPending()
                        stop()
                    } label: { Label("Stop belt", systemImage: "stop.fill") }
                    .buttonStyle(BeltButtonStyle(tint: .beltStop))
                    .disabled(!canStop)
                    .keyboardShortcut(.space, modifiers: [])
                } else {
                    Button {
                        starting = true
                        start()
                    } label: {
                        if starting {
                            Label { Text("Starting…") } icon: { ProgressView().controlSize(.small) }
                        } else {
                            Label("Start", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(BeltButtonStyle(tint: .beltStart))
                    .disabled(!canControl || starting)
                    if actualKmh == nil {
                        Button { stop() } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(BeltButtonStyle(tint: .beltStop))
                            .disabled(!canStop)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: starting)
    }

    private func change(to kmh: Double, delay: Duration) {
        target = kmh
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: delay)
            // Wait out an in-flight command instead of failing as busy.
            for _ in 0..<30 where live().busy { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            guard live().moving, !live().busy else {
                if target == kmh { target = nil }
                return
            }
            setSpeed(kmh)
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled, target == kmh { target = nil }
        }
    }

    private func cancelPending() { pending?.cancel(); pending = nil }
}

/// The belt's primary actions. Glass tint loses its color in inactive windows, so the
/// color is a solid fill under clear glass: Start and Stop always read as green and red.
struct BeltButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(tint.gradient, in: .capsule)
            .contentShape(Capsule())
            .glassEffect(.clear.interactive(), in: .capsule)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension Color {
    /// Deep enough for white semibold labels in light and dark appearance.
    static let beltStart = Color(.sRGB, red: 0.13, green: 0.58, blue: 0.27)
    static let beltStop = Color(.sRGB, red: 0.82, green: 0.19, blue: 0.17)
}
