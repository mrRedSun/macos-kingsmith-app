import SwiftUI
import WalkingPadCore

struct GlassNavigation: View {
    @Binding var showHistory: Bool
    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 12) {
                tab("Walking pad", symbol: "figure.walk", history: false)
                tab("History", symbol: "clock", history: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Popup view")
    }
    private func tab(_ title: String, symbol: String, history: Bool) -> some View {
        let selected = showHistory == history
        return Button { showHistory = history } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(selected ? Color.accentColor.opacity(0.15) : .clear).interactive(), in: .capsule)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct MetricReadout: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.medium))
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct InlineNotice<Actions: View>: View {
    let message: String
    let symbol: String
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: symbol).fixedSize(horizontal: false, vertical: true)
            actions().buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your walks").font(.system(.title3, design: .rounded).weight(.semibold))
                    Text("Activity recorded while connected").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.exportCSV() } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.glass).help("Export CSV").accessibilityLabel("Export walks as CSV")
            }
            if !model.storageReady {
                Text("Statistics aren't ready yet.").font(.callout).foregroundStyle(.secondary)
            } else if model.sessions.isEmpty {
                ContentUnavailableView("Your first walk starts here", systemImage: "figure.walk",
                                       description: Text("Connect your pad to start recording activity."))
                    .padding(.vertical, 16)
            }
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.sessions) { session in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.callout.weight(.medium))
                            Spacer()
                        }
                        HStack {
                            Text(DisplayFormat.distance(session.distanceMeters, imperial: model.imperial))
                            Spacer()
                            Text(DisplayFormat.duration(session.seconds, estimated: session.estimatedTime))
                        }.font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                        Text(session.hasSteps ? "\(session.steps) observed steps" : "Steps unavailable")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
    }
}

extension Metric {
    var symbol: String {
        switch self {
        case .speed: "speedometer"
        case .steps: "shoeprints.fill"
        case .distance: "arrow.left.and.right"
        case .duration: "timer"
        }
    }
}
