import CoreBluetooth
import Foundation

/// Where one-time keyboard setup has got to. The UI renders this directly, so
/// every state a person can wait in is named rather than inferred from a string.
enum SetupPhase: Equatable {
    case bluetoothOff
    case bluetoothDenied
    case scanning
    case found
    case connecting
    case preparing
    case ready
    case setupWindowClosed
    case sending
    case waitingForWiFi
    case connected
    case failed(String)

    /// Something is happening that the person is waiting on.
    var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .preparing, .sending, .waitingForWiFi: return true
        default: return false
        }
    }

    /// The sentence shown in the app and returned through MCP `get_status`.
    var message: String {
        switch self {
        case .bluetoothOff: return "Turn on Bluetooth to set up the keyboard."
        case .bluetoothDenied: return "Allow Bluetooth for EWP in Settings."
        case .scanning: return "Looking for a keyboard…"
        case .found: return "Choose the keyboard to set up."
        case .connecting: return "Connecting…"
        case .preparing: return "Checking the setup window…"
        case .ready: return "Ready for Wi-Fi details."
        case .setupWindowClosed: return "The setup window has closed. Reset the keyboard to reopen it for five minutes."
        case .sending: return "Sending Wi-Fi details to the keyboard…"
        case .waitingForWiFi: return "Waiting for the keyboard to join Wi-Fi…"
        case .connected: return "The keyboard is on Wi-Fi. Pair it in Settings → Bluetooth."
        case .failed(let reason): return reason
        }
    }
}

@MainActor
final class Provisioning: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let service = CBUUID(string: "e7a00001-7c3d-4d21-a19a-455750000001")
    static let config = CBUUID(string: "e7a00002-7c3d-4d21-a19a-455750000001")
    static let status = CBUUID(string: "e7a00003-7c3d-4d21-a19a-455750000001")

    @Published var nearby: [CBPeripheral] = []
    @Published private(set) var phase: SetupPhase = .scanning
    @Published private var displayNames: [UUID: String] = [:]

    /// Kept for the MCP surface, which reports setup state as text.
    var message: String { phase.message }
    var ready: Bool { phase == .ready }
    var selectedBluetoothID: String? { peripheral?.identifier.uuidString }
    var selectedName: String? { peripheral.map(displayName) }

    func displayName(_ device: CBPeripheral) -> String {
        displayNames[device.identifier] ?? device.name ?? "EWP Keyboard"
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var timeout: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?
    private var setupOpen: Bool?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func set(_ phase: SetupPhase) {
        guard self.phase != phase else { return }
        self.phase = phase
    }

    func rescan() {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        if let peripheral, peripheral.state == .connected {
            nearby = [peripheral]
            displayNames = displayNames.filter { $0.key == peripheral.identifier }
        } else {
            nearby.removeAll()
            displayNames.removeAll()
        }
        central.scanForPeripherals(withServices: [Self.service])
        if !phase.isBusy, phase != .ready, phase != .connected { set(.scanning) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: [Self.service])
            set(nearby.isEmpty ? .scanning : .found)
        case .unauthorized:
            set(.bluetoothDenied)
        default:
            set(.bluetoothOff)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            displayNames[peripheral.identifier] = name
        }
        if !nearby.contains(where: { $0.identifier == peripheral.identifier }) {
            nearby.append(peripheral)
        }
        if phase == .scanning { set(.found) }
    }

    func connect(_ device: CBPeripheral) {
        if peripheral == device, device.state == .connected, characteristic != nil {
            set(setupOpen == true ? .ready : .setupWindowClosed)
            return
        }
        if let peripheral, peripheral != device { central.cancelPeripheralConnection(peripheral) }
        peripheral = device
        characteristic = nil
        setupOpen = nil
        device.delegate = self
        set(.connecting)
        central.connect(device)
        // CoreBluetooth never gives up on its own, so a board that is out of
        // range would otherwise leave the person watching "Connecting…" forever.
        connectTimeout?.cancel()
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.phase == .connecting || self.phase == .preparing else { return }
            self.central.cancelPeripheralConnection(device)
            self.set(.failed("The keyboard did not respond. Move closer to it, then try again."))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        set(.preparing)
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectTimeout?.cancel()
        set(.failed(error?.localizedDescription ?? "Could not connect to the keyboard. Try again."))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectTimeout?.cancel()
        timeout?.cancel()
        characteristic = nil
        setupOpen = nil
        guard phase != .connected else { return }
        set(.failed("The keyboard disconnected. Choose it again to reconnect."))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { connectTimeout?.cancel(); set(.failed(error.localizedDescription)); return }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics([Self.config, Self.status], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { connectTimeout?.cancel(); set(.failed(error.localizedDescription)); return }
        for item in service.characteristics ?? [] {
            if item.uuid == Self.config { characteristic = item; set(.preparing) }
            if item.uuid == Self.status {
                peripheral.setNotifyValue(true, for: item)
                peripheral.readValue(for: item)
            }
        }
    }

    func configure(ssid: String, password: String) throws {
        guard let peripheral, let characteristic else { throw EWPError.message("Choose a keyboard first.") }
        guard ready else { throw EWPError.message(phase.message) }
        guard !ssid.isEmpty, ssid.utf8.count <= 32, password.utf8.count <= 64 else {
            throw EWPError.message("Enter the 2.4 GHz Wi-Fi name and password.")
        }
        let data = try JSONSerialization.data(withJSONObject: ["ssid": ssid, "password": password])
        guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            throw EWPError.message("Those Wi-Fi details are too long to send over Bluetooth.")
        }
        set(.sending)
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, self.phase == .waitingForWiFi || self.phase == .sending else { return }
            self.set(.failed("The keyboard did not join Wi-Fi. Check the name and password, and that the network is 2.4 GHz. Reset the keyboard to try again."))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            timeout?.cancel()
            set(.failed(error.localizedDescription))
            return
        }
        // A successful GATT write only confirms transport, not Wi-Fi association.
        if phase == .sending { set(.waitingForWiFi) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value,
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        connectTimeout?.cancel()
        setupOpen = doc["setup_open"] as? Bool
        if doc["state"] as? String == "connected" {
            timeout?.cancel()
            set(.connected)
            return
        }
        // A late status notification must not undo a finished setup, nor
        // interrupt a write that is already in flight.
        guard phase != .connected else { return }
        guard !phase.isBusy || phase == .preparing else { return }
        if setupOpen == true, self.characteristic != nil {
            set(.ready)
        } else if setupOpen == false {
            set(.setupWindowClosed)
        }
    }
}
