// Read-only macOS CoreBluetooth acceptance check. No HID descriptor reads or input.
import Foundation
import CoreBluetooth

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let target: String
    init(target: String) { self.target = target; super.init() }
    let serviceID = CBUUID(string: "e7a00001-7c3d-4d21-a19a-455750000001")
    let configID = CBUUID(string: "e7a00002-7c3d-4d21-a19a-455750000001")
    let statusID = CBUUID(string: "e7a00003-7c3d-4d21-a19a-455750000001")
    var manager: CBCentralManager!
    var device: CBPeripheral?
    var writable = false
    func start() { manager = CBCentralManager(delegate: self, queue: .main) }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { central.scanForPeripherals(withServices: [serviceID]) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String:Any], rssi RSSI: NSNumber) {
        guard peripheral.name == target, device == nil else { return }
        device = peripheral; peripheral.delegate = self; central.stopScan(); central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected; discovering EWP service only")
        peripheral.discoverServices([serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { print("Connect failed"); exit(1) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { print("Disconnected"); exit(1) }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: {$0.uuid == serviceID}) else { print("Service missing"); exit(1) }
        print("EWP service discovered")
        peripheral.discoverCharacteristics([configID,statusID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { print("Characteristic discovery failed"); exit(1) }
        writable = service.characteristics?.contains(where: {$0.uuid == configID && $0.properties.contains(.write)}) ?? false
        guard writable, let status = service.characteristics?.first(where: {$0.uuid == statusID}) else { print("Configuration or status characteristic missing"); exit(1) }
        print("EWP characteristics discovered; reading status")
        peripheral.readValue(for: status)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data=characteristic.value, let status = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { print("Read failed"); exit(1) }
        let output: [String:Any] = ["status_read":true,"configuration_write":writable,"id":status["id"] ?? "","state":status["state"] ?? "","setup_open":status["setup_open"] ?? false]
        print(String(data:try! JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
        manager.cancelPeripheralConnection(peripheral)
        exit(0)
    }
    func timeout() { if let device {manager.cancelPeripheralConnection(device)}; print("Native BLE probe timed out"); exit(1) }
}
guard let nameIndex = CommandLine.arguments.firstIndex(of: "--name"), nameIndex + 1 < CommandLine.arguments.count else {
    print("Usage: xcrun swift firmware/check_ble.swift --name ewp-your-board-name")
    exit(2)
}
let probe = Probe(target: CommandLine.arguments[nameIndex + 1])
probe.start()
DispatchQueue.main.asyncAfter(deadline: .now()+25) {probe.timeout()}
RunLoop.main.run()
