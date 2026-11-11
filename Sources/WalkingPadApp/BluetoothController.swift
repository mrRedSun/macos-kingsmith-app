import Foundation
import CoreBluetooth
import Combine
import WalkingPadCore

@MainActor
final class BluetoothController: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    struct Device: Identifiable {
        let peripheral: CBPeripheral
        let name: String
        var id: UUID { peripheral.identifier }
    }
    @Published private(set) var devices: [Device] = []
    @Published private(set) var status = "Ready to connect"
    @Published private(set) var connectedName: String?
    @Published private(set) var profile: PadProfile?
    @Published private(set) var connected = false
    @Published private(set) var scanning = false
    @Published private(set) var connecting = false
    /// A pending connection to the remembered pad. CoreBluetooth keeps it open
    /// indefinitely and completes it when the pad wakes up.
    @Published private(set) var waitingForPad = false
    @Published private(set) var stopQueued = false
    @Published private(set) var hasControl = false
    @Published private(set) var busy = false
    @Published private(set) var fresh = false
    @Published private(set) var telemetry = FTMS.Telemetry()
    @Published private(set) var speedRange = FTMS.SpeedRange.conservative
    @Published private(set) var commandNotice: String?
    /// Set when the app stopped an empty belt; cleared by the next Start.
    @Published private(set) var steppedOffStop = false
    @Published var errorMessage: String?
    var onTelemetry: ((FTMS.Telemetry) -> Void)?
    var onPadRecord: ((LegacyProtocol.Record) -> Void)?
    var onDisconnect: (() -> Void)?
    var stepExtension = false {
        didSet {
            if oldValue != stepExtension, profile == .ftms { telemetry.steps = nil }
        }
    }
    var autoConnect = false {
        didSet {
            guard autoConnect != oldValue else { return }
            if autoConnect { scheduleReconnect(after: .zero) }
            else { reconnectTask?.cancel(); if waitingForPad { closeConnection() } }
        }
    }
    /// Seconds without walking before an empty belt is stopped; nil turns it off.
    /// KingSmith pads only: their counters advance only while someone walks.
    var stepOffDelay: TimeInterval? {
        didSet { stepOff.delay = stepOffDelay ?? 0; stepOff.reset() }
    }
    private var stepOff = StepOffDetector(delay: 5)
    var stepsAvailable: Bool { profile != .ftms || stepExtension }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var commandQueue = ControlQueue()
    private var legacyWrites = LegacyWriteQueue()
    private var legacyDecoder = LegacyProtocol.StreamDecoder()
    private var legacyUnsent: LegacyProtocol.Command?
    private var recoveringLegacyStop = false
    private var connectionTimeout: Task<Void, Never>?
    private var commandTimeout: Task<Void, Never>?
    private var staleTimeout: Task<Void, Never>?
    private var scanTimeout: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var legacyDelay: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// When to ask a KingSmith pad for its stored walk: on connect and after each Stop.
    private var historyDue: Date?
    private var historyAttempts = 0
    private var userDisconnected = false
    private static let rememberedID = "rememberedPadID", rememberedName = "rememberedPadName"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func scan() {
        guard central.state == .poweredOn else {
            errorMessage = "Enable Bluetooth and allow WalkingPad in System Settings > Privacy & Security > Bluetooth."
            return
        }
        guard peripheral == nil else { return }
        devices = []; scanning = true; errorMessage = nil; status = "Looking for your pad…"
        // A pad already connected to this Mac (by another app or session) stops advertising.
        let services = PadProfile.discoveryServices.map { CBUUID(string: $0) }
        for peripheral in central.retrieveConnectedPeripherals(withServices: services) {
            devices.append(Device(peripheral: peripheral, name: peripheral.name ?? "Walking pad"))
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self else { return }
            self.stopScan()
            self.status = self.devices.isEmpty ? "No pad found" : "Choose your pad"
        }
    }

    func stopScan() { central.stopScan(); scanning = false; scanTimeout?.cancel() }

    func connect(_ device: Device, automatic: Bool = false) {
        guard peripheral == nil else { return }
        guard device.peripheral.state == .disconnected else {
            if automatic { scheduleReconnect() }
            else { errorMessage = "The previous connection is still closing. Try again in a moment." }
            return
        }
        reconnectTask?.cancel()
        // Keep safety errors visible across automatic reconnects.
        if !automatic { userDisconnected = false; errorMessage = nil }
        stopScan(); connecting = true; waitingForPad = automatic; commandNotice = nil
        telemetry = .init(); speedRange = .conservative
        connectedName = device.name
        peripheral = device.peripheral; device.peripheral.delegate = self
        status = automatic ? "Waiting for \(device.name)" : "Connecting…"
        central.connect(device.peripheral)
        if !automatic { armSetupTimeout() }
    }

    private func armSetupTimeout() {
        connectionTimeout?.cancel()
        connectionTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            self.errorMessage = "Connection setup timed out. Wake the pad and close other walking-pad apps."
            self.closeConnection()
        }
    }

    private func scheduleReconnect(after delay: Duration = .seconds(3)) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reconnectRemembered()
        }
    }
    private func reconnectRemembered() {
        let defaults = UserDefaults.standard
        guard autoConnect, !userDisconnected, central.state == .poweredOn, peripheral == nil, !scanning,
              let id = defaults.string(forKey: Self.rememberedID).flatMap(UUID.init(uuidString:)),
              let pad = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        let name = pad.name ?? defaults.string(forKey: Self.rememberedName) ?? "Walking pad"
        connect(Device(peripheral: pad, name: name), automatic: true)
    }

    /// User-initiated: auto-connect stays off until the user picks a pad again or relaunches.
    func disconnect() {
        userDisconnected = true
        closeConnection()
    }
    private func closeConnection() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        clearConnection()
    }

    func start() {
        steppedOffStop = false
        if profile == .ftms { sendFTMS(FTMS.start) }
        else { sendLegacy(.start) }
    }
    func stop() {
        if profile == .ftms { sendFTMS(FTMS.stop) }
        else { sendLegacy(.stop) }
    }
    func setSpeed(_ kmh: Double) {
        do {
            let data = try FTMS.setSpeed(kmh, range: speedRange)
            if profile == .ftms { sendFTMS(data) }
            else { sendLegacy(.speed(kmh)) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func sendFTMS(_ data: Data) {
        guard connected, control != nil else { errorMessage = "Connect your pad before sending controls."; return }
        do {
            let outgoing = try commandQueue.request(data, hasControl: hasControl, fresh: fresh)
            syncQueueState()
            if let outgoing { writeFTMS(outgoing) }
        } catch { errorMessage = error.localizedDescription }
    }
    private func writeFTMS(_ data: Data) {
        guard let peripheral, let control else { return }
        peripheral.writeValue(data, for: control, type: .withResponse)
        armCommandTimeout()
    }

    private func sendLegacy(_ command: LegacyProtocol.Command) {
        guard connected, hasControl, control != nil else {
            if command.isMotorCommand { errorMessage = "This connection is read only." }
            return
        }
        guard !command.isMotorCommand || command == .stop || fresh else {
            errorMessage = ControlQueue.Rejection.stale.localizedDescription
            return
        }
        do {
            // Backpressure means these bytes have NOT reached CoreBluetooth.
            // Stop can replace an unsent Start/speed without moving the belt first.
            if command == .stop, legacyUnsent != nil {
                legacyUnsent = nil; legacyWrites.reset(); commandTimeout?.cancel()
                legacyDelay?.cancel(); legacyDelay = nil
            }
            let outgoing = try legacyWrites.request(command)
            syncQueueState()
            if let outgoing { writeLegacy(outgoing) }
        } catch { errorMessage = error.localizedDescription }
    }
    private func writeLegacy(_ command: LegacyProtocol.Command) {
        guard let peripheral, let control else { return }
        do {
            let bytes = try command.encoded()
            let type: CBCharacteristicWriteType = control.properties.contains(.write) ? .withResponse : .withoutResponse
            armCommandTimeout()
            if type == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
                legacyUnsent = command
                return
            }
            legacyUnsent = nil
            peripheral.writeValue(bytes, for: control, type: type)
            if type == .withoutResponse { completeLegacyWrite() }
        } catch { errorMessage = error.localizedDescription; closeConnection() }
    }
    private func completeLegacyWrite() {
        commandTimeout?.cancel()
        if recoveringLegacyStop {
            errorMessage = "Stop was attempted after a write timeout. Check the pad and reconnect."
            closeConnection()
            return
        }
        if legacyWrites.inFlight?.isMotorCommand == true {
            commandNotice = "Command sent. Check the live speed and keep your remote nearby."
        }
        let finished = legacyWrites.inFlight
        let next = legacyWrites.complete()
        syncQueueState()
        guard let next else { return }
        guard finished == .manualMode else { writeLegacy(next); return }
        // KS-BDC2 ignores a Start sent together with the mode change but accepts one 0.3 s
        // later. Until it is written, Start counts as unsent, so Stop cancels it outright.
        legacyUnsent = next
        armCommandTimeout()
        legacyDelay = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.legacyUnsent == next else { return }
            self.legacyDelay = nil
            self.writeLegacy(next)
        }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, legacyDelay == nil, let command = legacyUnsent else { return }
        writeLegacy(command)
    }

    private func syncQueueState() {
        busy = profile == .ftms ? commandQueue.busy : legacyWrites.busy
        stopQueued = profile == .ftms ? commandQueue.stopQueued : legacyWrites.stopQueued
    }
    private func armCommandTimeout() {
        commandTimeout?.cancel()
        commandTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            if self.profile == .ftms, let stop = self.commandQueue.timeout(hasControl: self.hasControl) {
                self.syncQueueState()
                self.errorMessage = "Command timed out. Attempting queued Stop. Use the physical remote now."
                self.writeFTMS(stop)
            } else if self.profile != .ftms, let stop = self.legacyWrites.timeout() {
                self.legacyUnsent = nil; self.recoveringLegacyStop = true; self.syncQueueState()
                self.errorMessage = "Write timed out. Attempting queued Stop. Use the physical remote now."
                self.writeLegacy(stop)
            } else {
                self.errorMessage = "No response to the write. Belt state is unknown. Use the physical remote and reconnect."
                self.closeConnection()
            }
        }
    }

    private func acquireWhenReady() {
        guard !connected, let profile, dataCharacteristic?.isNotifying == true,
              profile != .ftms || control == nil || control?.isNotifying == true else { return }
        connected = true; connecting = false; connectionTimeout?.cancel()
        if let peripheral {
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.rememberedID)
            UserDefaults.standard.set(connectedName, forKey: Self.rememberedName)
        }
        if profile == .ftms, control != nil {
            status = "Requesting control…"
            sendFTMS(FTMS.requestControl)
        } else {
            hasControl = control != nil
            status = hasControl ? "Connected" : "Connected, read only"
            if hasControl {
                historyDue = Date()
                pollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        self.sendLegacy(self.nextQuery())
                        try? await Task.sleep(for: .seconds(1)) // Legacy pads only report when asked.
                    }
                }
            }
        }
        armStaleTimeout()
    }
    private func nextQuery() -> LegacyProtocol.Command {
        guard let due = historyDue, due <= Date() else { return .statistics }
        historyAttempts += 1
        if historyAttempts >= 5 { historyDue = nil; historyAttempts = 0 }
        return .history
    }
    private func receive(_ record: LegacyProtocol.Record?) {
        historyDue = nil; historyAttempts = 0
        // The query returns the latest walk every time; one read per trigger is enough.
        if let record { onPadRecord?(record) }
    }
    private func receive(_ update: FTMS.Telemetry) {
        if profile != .ftms, (telemetry.speedKmh ?? 0) > 0, update.speedKmh == 0 {
            historyDue = Date().addingTimeInterval(3) // The pad stores the walk once the belt stops.
        }
        telemetry.merge(update); fresh = true; armStaleTimeout()
        if profile != .ftms, hasControl, stepOffDelay != nil, stepOff.update(telemetry, at: Date()) {
            steppedOffStop = true
            stop()
        }
        status = hasControl ? "Connected" : "Connected, read only"
        onTelemetry?(update)
    }
    private func armStaleTimeout() {
        staleTimeout?.cancel()
        staleTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            self.fresh = false; self.status = "Waiting for pad data"
        }
    }
    private func clearConnection() {
        connectionTimeout?.cancel(); commandTimeout?.cancel(); staleTimeout?.cancel(); pollTask?.cancel()
        legacyDelay?.cancel(); legacyDelay = nil
        peripheral?.delegate = nil; peripheral = nil; control = nil; dataCharacteristic = nil
        commandQueue.reset(); legacyWrites.reset(); legacyDecoder = .init()
        legacyUnsent = nil; recoveringLegacyStop = false; profile = nil
        historyDue = nil; historyAttempts = 0; stepOff.reset()
        stopQueued = false; busy = false; connecting = false; waitingForPad = false
        connected = false; hasControl = false; fresh = false
        telemetry = .init(); commandNotice = nil; status = "Disconnected"
        onDisconnect?()
        if autoConnect, !userDisconnected { scheduleReconnect() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: status = "Ready to connect"; scheduleReconnect(after: .zero)
        case .poweredOff: stopScan(); clearConnection(); status = "Bluetooth is off"
        case .unauthorized: stopScan(); clearConnection(); status = "Bluetooth permission denied"
        case .unsupported: status = "Bluetooth LE is not supported"
        default: stopScan(); clearConnection(); status = "Bluetooth unavailable"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard PadProfile.isCandidate(name: name, services: services.map(\.uuidString)),
              !devices.contains(where: { $0.id == peripheral.identifier }) else { return }
        devices.append(Device(peripheral: peripheral, name: name ?? "Walking pad"))
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, peripheral.state == .connected else { return }
        if waitingForPad { waitingForPad = false; armSetupTimeout() }
        status = "Checking pad services…"
        // One-time discovery of all services also makes unknown-firmware errors useful.
        peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral, peripheral.state == .disconnected else { return }
        errorMessage = error?.localizedDescription ?? "Could not connect to pad."
        clearConnection()
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral, peripheral.state == .disconnected else { return }
        if let error { errorMessage = error.localizedDescription }
        clearConnection()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        let services = peripheral.services ?? []
        guard error == nil, let selected = PadProfile.detect(services: services.map { $0.uuid.uuidString }),
              let service = services.first(where: { $0.uuid == CBUUID(string: selected.service) }) else {
            let identifiers = services.map { $0.uuid.uuidString }.joined(separator: ", ")
            errorMessage = error?.localizedDescription ?? "No supported WalkingPad service found. Discovered: \(identifiers.isEmpty ? "none" : identifiers)."
            closeConnection(); return
        }
        profile = selected
        let identifiers = [selected.notify, selected.write] + (selected == .ftms ? [FTMS.speedRange] : [])
        peripheral.discoverCharacteristics(identifiers.map { CBUUID(string: $0) }, for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, let profile else { return }
        guard error == nil else { errorMessage = error?.localizedDescription; closeConnection(); return }
        let characteristics = service.characteristics ?? []
        func notifies(_ c: CBCharacteristic) -> Bool { c.properties.contains(.notify) || c.properties.contains(.indicate) }
        func writes(_ c: CBCharacteristic) -> Bool { c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) }
        if profile == .ftms {
            for characteristic in characteristics {
                if characteristic.uuid == CBUUID(string: profile.notify), notifies(characteristic) {
                    dataCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if characteristic.uuid == CBUUID(string: profile.write),
                          characteristic.properties.contains(.write), characteristic.properties.contains(.indicate) {
                    control = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if characteristic.uuid == CBUUID(string: FTMS.speedRange), characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
            }
        } else {
            // Published references disagree on which legacy characteristic notifies,
            // so confirm roles from properties, preferring the verified mapping.
            let pair = characteristics.filter { [profile.notify, profile.write].map { CBUUID(string: $0) }.contains($0.uuid) }
            let data = pair.first { $0.uuid == CBUUID(string: profile.notify) && notifies($0) } ?? pair.first(where: notifies)
            control = pair.first { $0.uuid == CBUUID(string: profile.write) && writes($0) && $0 !== data }
                ?? pair.first { writes($0) && $0 !== data }
            if let data { dataCharacteristic = data; peripheral.setNotifyValue(true, for: data) }
        }
        if dataCharacteristic == nil {
            errorMessage = "\(profile.title) was found, but its telemetry characteristic is missing."
            closeConnection()
        } else if control == nil {
            errorMessage = "This firmware exposes telemetry without a supported control characteristic."
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error {
            errorMessage = error.localizedDescription
            if characteristic === control { control = nil; acquireWhenReady() }
            else { closeConnection() }
            return
        }
        acquireWhenReady()
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === control else { return }
        if let error { errorMessage = "\(error.localizedDescription) Check the belt with your physical remote."; closeConnection(); return }
        if profile != .ftms { completeLegacyWrite() }
        // FTMS GATT success isn't a procedure response; wait for its indication.
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error { errorMessage = error.localizedDescription; return }
        guard let data = characteristic.value, let profile else { return }
        do {
            if characteristic === dataCharacteristic {
                if profile == .ftms { receive(try FTMS.decode(data, c2StepExtension: stepExtension)) }
                else {
                    for frame in legacyDecoder.append(data) {
                        switch frame {
                        case .status(let update): receive(update)
                        case .record(let record): receive(record)
                        }
                    }
                }
            } else if characteristic === control, profile == .ftms {
                let response = try FTMS.Response(data)
                guard response.opcode == commandQueue.pendingOpcode else { return }
                commandTimeout?.cancel()
                if response.opcode == 0 { hasControl = response.succeeded }
                if !response.succeeded {
                    errorMessage = response.message
                    if response.result == 5 { hasControl = false }
                }
                let next = commandQueue.complete(opcode: response.opcode, hasControl: hasControl)
                syncQueueState()
                if let next { writeFTMS(next) }
                status = hasControl ? "Connected" : "Connected, read only"
            } else if characteristic.uuid == CBUUID(string: FTMS.speedRange), profile == .ftms {
                let reported = try FTMS.SpeedRange(data: data)
                let minimum = reported.minimum + ceil((max(0.5, reported.minimum) - reported.minimum) / reported.increment - 0.000001) * reported.increment
                speedRange = .init(minimum: minimum, maximum: min(6, reported.maximum), increment: reported.increment)
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
