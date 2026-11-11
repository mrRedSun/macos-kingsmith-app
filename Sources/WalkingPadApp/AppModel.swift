import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import WalkingPadCore

@MainActor
final class AppModel: ObservableObject {
    let bluetooth = BluetoothController()
    @Published private(set) var sessions: [WalkingSession] = []
    @Published var storageError: String?
    @Published var exportError: String?
    @Published var quitNeedsConfirmation = false
    @Published private(set) var quitting = false
    @Published private(set) var storageReady = false
    @Published private(set) var pendingWrites = 0
    @Published var imperial = UserDefaults.standard.bool(forKey: "imperial") {
        didSet { UserDefaults.standard.set(imperial, forKey: "imperial") }
    }
    @Published var barMetrics: [String] = UserDefaults.standard.stringArray(forKey: "barMetrics") ?? [] {
        didSet { UserDefaults.standard.set(barMetrics, forKey: "barMetrics") }
    }
    /// Stack menu-bar values two per column to save width.
    @Published var barStacked = UserDefaults.standard.object(forKey: "barStacked") as? Bool ?? true {
        didSet { UserDefaults.standard.set(barStacked, forKey: "barStacked") }
    }
    @Published var barSource = UserDefaults.standard.string(forKey: "barSource") ?? "session" {
        didSet { UserDefaults.standard.set(barSource, forKey: "barSource") }
    }
    /// Four speed presets in km/h, the unit the pad uses.
    @Published var speedPresets = SpeedControl.presets(UserDefaults.standard.array(forKey: "speedPresets") as? [Double],
                                                      range: .conservative) {
        didSet { UserDefaults.standard.set(speedPresets, forKey: "speedPresets") }
    }
    @Published var autoConnect = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: "autoConnect")
            bluetooth.autoConnect = autoConnect
        }
    }
    /// Stops the belt once nobody has walked on it for `stepOffDelay` seconds.
    @Published var stepOffStop = UserDefaults.standard.object(forKey: "stepOffStop") as? Bool ?? true {
        didSet { UserDefaults.standard.set(stepOffStop, forKey: "stepOffStop"); applyStepOff() }
    }
    @Published var stepOffDelay = UserDefaults.standard.object(forKey: "stepOffDelay") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(stepOffDelay, forKey: "stepOffDelay"); applyStepOff() }
    }
    private func applyStepOff() { bluetooth.stepOffDelay = stepOffStop ? TimeInterval(stepOffDelay) : nil }
    @Published var stepExtension = UserDefaults.standard.bool(forKey: "stepExtension") {
        didSet {
            UserDefaults.standard.set(stepExtension, forKey: "stepExtension")
            bluetooth.stepExtension = stepExtension
            accumulator.resetStepBaseline()
        }
    }
    private var accumulator = SessionAccumulator()
    private var store: SessionStore?
    private var openingStore = false
    private var dayChangeSubscription: AnyCancellable?
    private var unsaved: [UUID: WalkingSession] = [:]
    /// The pad walk this connection is following (KingSmith pads).
    private var padLive: UUID?
    private var padContinuing = false

    init() {
        barMetrics = MetricPreferences.enabled(barMetrics).map(\.rawValue)
        bluetooth.stepExtension = stepExtension
        bluetooth.autoConnect = autoConnect
        applyStepOff()
        bluetooth.onTelemetry = { [weak self] update in self?.record(update) }
        bluetooth.onPadRecord = { [weak self] record in self?.importPadRecord(record) }
        bluetooth.onDisconnect = { [weak self] in
            self?.accumulator.reset(); self?.padLive = nil; self?.padContinuing = false
        }
        dayChangeSubscription = NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
        openStore()
    }

    private func openStore() {
        guard !openingStore else { return }
        openingStore = true
        Task {
            defer { openingStore = false }
            do {
                let store = try await Task.detached(priority: .utility) {
                    let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                               in: .userDomainMask, appropriateFor: nil, create: true)
                    return try SessionStore(url: directory.appendingPathComponent("WalkingPad/statistics.sqlite"))
                }.value
                let existing = try await store.sessions()
                self.store = store
                let current = self.sessions
                self.sessions = existing.filter { row in !current.contains(where: { $0.id == row.id }) } + current
                self.sessions.sort { $0.startedAt > $1.startedAt }
                self.storageReady = true
                self.storageError = nil
                for session in unsaved.values { persist(session) }
            } catch { storageError = "Statistics are not saved: \(error.localizedDescription)" }
        }
    }

    private func record(_ update: FTMS.Telemetry) {
        guard bluetooth.profile == .ftms else { return followPadWalk(update) }
        guard let session = accumulator.ingest(update) else { return }
        upsert(session)
    }

    private func followPadWalk(_ update: FTMS.Telemetry) {
        let latest = padLive.flatMap { id in sessions.first { $0.id == id } }
            ?? sessions.filter(\.padTracked).max { $0.endedAt < $1.endedAt }
        guard let session = PadWalks.ingest(update, at: Date(), latest: latest, continuing: padContinuing) else { return }
        padLive = session.id; padContinuing = true
        if session.revision != latest?.revision || session.id != latest?.id { upsert(session) }
    }

    private func importPadRecord(_ record: LegacyProtocol.Record) {
        let defaults = UserDefaults.standard
        let merge = PadWalks.apply(record, at: Date(), sessions: sessions.filter(\.padTracked), live: padLive,
                                   clockOffset: defaults.object(forKey: "padClockOffset") as? Double)
        if let offset = merge.clockOffset { defaults.set(offset, forKey: "padClockOffset") }
        if let removed = merge.removed { remove(removed) }
        if padLive != nil, merge.removed != nil || merge.clockOffset != nil || merge.session.id == padLive {
            padLive = merge.session.id
        }
        if sessions.first(where: { $0.id == merge.session.id }) != merge.session { upsert(merge.session) }
    }

    private func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        unsaved[id] = nil
        guard let store else { return }
        Task {
            do { try await store.delete(id) }
            catch { storageError = "Statistics are not saved: \(error.localizedDescription)" }
        }
    }

    private func upsert(_ session: WalkingSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
        else { sessions.insert(session, at: 0); sessions.sort { $0.startedAt > $1.startedAt } }
        unsaved[session.id] = session
        persist(session)
    }

    private func persist(_ session: WalkingSession) {
        guard let store else { return }
        pendingWrites += 1
        Task {
            defer { pendingWrites -= 1 }
            do {
                try await store.save(session)
                if unsaved[session.id]?.revision == session.revision { unsaved[session.id] = nil }
                if unsaved.isEmpty { storageError = nil }
            } catch { storageError = "Statistics are not saved: \(error.localizedDescription)" }
        }
    }

    func retrySaving() {
        if store == nil { openStore() }
        else { for session in unsaved.values { persist(session) } }
    }

    var current: WalkingSession? { padLive.flatMap { id in sessions.first { $0.id == id } } ?? accumulator.session }
    var today: [WalkingSession] { sessions.filter { Calendar.current.isDateInToday($0.startedAt) } }
    var todayMeters: Int { today.reduce(0) { $0 + $1.distanceMeters } }
    var todaySeconds: Int { today.reduce(0) { $0 + $1.seconds } }
    var todaySteps: Int? { today.contains(where: \.hasSteps) ? today.reduce(0) { $0 + $1.steps } : nil }

    func value(_ metric: Metric, source: String, compact: Bool = false) -> String {
        let live = bluetooth.telemetry
        switch metric {
        case .speed: return DisplayFormat.speed(bluetooth.fresh ? live.speedKmh : nil, imperial: imperial, compact: compact)
        case .steps:
            let count: Int? = source == "pad" ? (bluetooth.fresh && bluetooth.stepsAvailable ? live.steps : nil)
                : source == "today" ? todaySteps : current.flatMap { $0.hasSteps ? $0.steps : nil }
            if compact { return count.map(String.init) ?? "—" }
            return count.map { "\($0) steps" } ?? "— steps"
        case .distance:
            let meters = source == "pad" ? (bluetooth.fresh ? live.distanceMeters : nil)
                : source == "today" ? todayMeters : current?.distanceMeters
            return DisplayFormat.distance(meters, imperial: imperial, compact: compact)
        case .duration:
            let seconds = source == "pad" ? (bluetooth.fresh ? live.elapsedSeconds : nil)
                : source == "today" ? todaySeconds : current?.seconds
            let estimated = source == "today" ? today.contains(where: \.estimatedTime)
                : source == "session" ? current?.estimatedTime == true : false
            return DisplayFormat.duration(seconds, estimated: estimated, compact: compact)
        }
    }

    /// Enabled menu-bar metrics with their unit-free values.
    var barReadings: [BarReadout.Reading] {
        barMetrics.compactMap(Metric.init(rawValue:)).map { .init(metric: $0, value: value($0, source: barSource, compact: true)) }
    }

    var barTitle: String {
        let text = barMetrics.compactMap(Metric.init(rawValue:)).map { value($0, source: barSource) }.joined(separator: " · ")
        return text.isEmpty ? "" : text
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "walkingpad-sessions.csv"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = sessions
        exportError = nil
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try SessionStore.csv(snapshot).write(to: url, atomically: true, encoding: .utf8)
                }.value
            } catch { exportError = "CSV export failed: \(error.localizedDescription)" }
        }
    }

    func quit() {
        guard !quitting else { return }
        quitting = true
        Task {
            // Freeze no connection state until we know the user can quit.
            while pendingWrites > 0 { try? await Task.sleep(for: .milliseconds(20)) }
            quitting = false
            guard unsaved.isEmpty else {
                quitNeedsConfirmation = true
                return
            }
            terminate()
        }
    }

    func terminate() {
        // Deliberately no motor command. The user must stop the belt separately.
        bluetooth.disconnect()
        NSApp.terminate(nil)
    }
}
