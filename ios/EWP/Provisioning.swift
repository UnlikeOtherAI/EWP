import CoreBluetooth
import Foundation

@MainActor
final class Provisioning: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "e7a00001-7c3d-4d21-a19a-455750000001")
    static let config = CBUUID(string: "e7a00002-7c3d-4d21-a19a-455750000001")
    static let status = CBUUID(string: "e7a00003-7c3d-4d21-a19a-455750000001")
    @Published var nearby: [CBPeripheral] = []
    @Published var message = "Looking for ESP32…"
    @Published var ready = false
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [Self.service])
            message = "Looking for ESP32…"
        } else {
            message = central.state == .unauthorized ? "Allow Bluetooth in Settings." : "Turn on Bluetooth to set up the ESP32."
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !nearby.contains(where: { $0.identifier == peripheral.identifier }) { nearby.append(peripheral) }
    }

    func connect(_ device: CBPeripheral) {
        if let peripheral, peripheral != device { central.cancelPeripheralConnection(peripheral) }
        peripheral = device
        characteristic = nil
        ready = false
        device.delegate = self
        message = "Connecting…"
        central.connect(device)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        message = error?.localizedDescription ?? "Could not connect. Try again."
        ready = false
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        ready = false
        characteristic = nil
        message = "ESP32 disconnected. Tap it to reconnect."
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { message = error.localizedDescription; return }
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics([Self.config, Self.status], for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { message = error.localizedDescription; return }
        for item in service.characteristics ?? [] {
            if item.uuid == Self.config { characteristic = item; ready = true; message = "Ready for Wi-Fi setup." }
            if item.uuid == Self.status { peripheral.setNotifyValue(true, for: item); peripheral.readValue(for: item) }
        }
    }

    func configure(ssid: String, password: String, token: String) throws {
        guard let peripheral, let characteristic else { throw EWPError.message("Choose an ESP32 first.") }
        guard !ssid.isEmpty, ssid.utf8.count <= 32, password.utf8.count <= 64,
              token.count == 64, token.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw EWPError.message("Enter the Wi-Fi name and the bridge's 64-character pairing token.")
        }
        let data = try JSONSerialization.data(withJSONObject: ["ssid": ssid, "password": password, "token": token])
        guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            throw EWPError.message("Wi-Fi setup exceeds the Bluetooth write limit.")
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        message = "Pair using the code from the ESP32's serial console, then wait for Wi-Fi."
        timeout?.cancel()
        timeout = Task {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled else { return }
            message = "No Wi-Fi confirmation. Check credentials and 2.4 GHz Wi-Fi; reset the ESP32 to reopen setup."
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { timeout?.cancel(); message = error.localizedDescription }
        // A successful GATT write only confirms transport, not Wi-Fi association.
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value,
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if doc["state"] as? String == "connected" {
            timeout?.cancel()
            message = "ESP32 is on Wi-Fi. Pair it as a keyboard in Settings → Bluetooth."
        }
        if doc["setup_open"] as? Bool == false, doc["state"] as? String != "connected" {
            message = "Setup window closed. Reset the ESP32 to reopen it for five minutes."
        }
    }
}
