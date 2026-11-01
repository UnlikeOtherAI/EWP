import Foundation
import Security

/// Access to EWP devices other than this one. Each device issues its own
/// token, so renaming one means holding its token; tokens are kept in the
/// keychain, never in defaults and never shown after they are entered.
@MainActor
final class RemoteDevices: ObservableObject {
    /// A device whose access token this device holds, whether or not that
    /// device is answering on this network right now.
    struct Saved: Identifiable, Equatable {
        let id: String
        /// What the device called itself when it was last seen, if ever. The
        /// device owns its name; this is kept only so that a device which is
        /// switched off stays recognisable here, with the identifier as truth.
        let lastSeenName: String?

        var title: String {
            let trimmed = lastSeenName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? String(id.prefix(8)) : trimmed
        }
    }

    @Published private(set) var saved: [Saved] = []
    /// Saved devices that are still advertised but did not answer.
    @Published private(set) var silent: Set<String> = []
    private var cursor = 0

    init() { saved = Self.stored() }

    private static let service = "ewp.remote-device"

    private struct Record: Codable {
        var token: String
        var lastSeenName: String?
    }

    private static func query(_ deviceID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: deviceID]
    }

    /// Items written before a label was kept hold the bare token, so data that
    /// is not JSON is read as the token itself.
    private static func decode(_ data: Data) -> Record {
        if let record = try? JSONDecoder().decode(Record.self, from: data) { return record }
        return Record(token: String(data: data, encoding: .utf8) ?? "")
    }

    private static func sort(_ devices: [Saved]) -> [Saved] {
        devices.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func stored() -> [Saved] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true,
                                    kSecReturnData as String: true]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let items = value as? [[String: Any]] else { return [] }
        return sort(items.compactMap { item in
            guard let id = item[kSecAttrAccount as String] as? String else { return nil }
            let data = item[kSecValueData as String] as? Data
            return Saved(id: id, lastSeenName: data.flatMap { decode($0).lastSeenName })
        })
    }

    private func record(for deviceID: String) -> Record? {
        var query = Self.query(deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return Self.decode(data)
    }

    func token(for deviceID: String) -> String? { record(for: deviceID)?.token }

    func hasToken(for deviceID: String) -> Bool { saved.contains { $0.id == deviceID } }

    /// Saved devices that are not answering on this network. Listing them is
    /// what makes a stale entry removable rather than invisible: a device whose
    /// identifier changed, because its app was reinstalled, comes back as a new
    /// device, and its old entry would otherwise sit in the keychain for good.
    func absent(from discovered: [DiscoveredDevice]) -> [Saved] {
        let answering = Set(discovered.map(\.id)).subtracting(silent)
        return saved.filter { !answering.contains($0.id) }
    }

    /// Asks one saved device whether it is really there. Bonjour keeps
    /// advertising a device long after it has gone — a record outlives the
    /// device by its time to live, and restarting the browser only reads the
    /// same cache — so presence is taken from an answer, not an advertisement.
    /// One device per tick, in turn, keeps a wall of them off the network.
    func verify(_ discovered: [DiscoveredDevice]) async {
        let mine = discovered.filter { hasToken(for: $0.id) }
        guard !mine.isEmpty else { return }
        let device = mine[cursor % mine.count]
        cursor = (cursor + 1) % mine.count
        guard let url = device.primary?.url, let token = token(for: device.id) else { return }
        do {
            _ = try await DeviceHTTP.call(url: url, token: token, name: "help", timeout: 2)
            silent.remove(device.id)
        } catch {
            silent.insert(device.id)
        }
    }

    /// Records the name a saved device is publishing now. The in-memory label
    /// is checked first so that a poll over a wall of devices does not read the
    /// keychain for every one of them on every tick.
    func note(_ devices: [DiscoveredDevice]) {
        for device in devices {
            guard let name = device.givenName, !name.isEmpty,
                  let index = saved.firstIndex(where: { $0.id == device.id }),
                  saved[index].lastSeenName != name,
                  var stored = record(for: device.id) else { continue }
            stored.lastSeenName = name
            try? write(stored, for: device.id)
        }
    }

    private func write(_ record: Record, for deviceID: String) throws {
        let data = try JSONEncoder().encode(record)
        let status = SecItemUpdate(Self.query(deviceID) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.query(deviceID)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw EWPError.message("Could not save that access token.")
            }
        } else if status != errSecSuccess {
            throw EWPError.message("Could not save that access token.")
        }
        saved.removeAll { $0.id == deviceID }
        saved = Self.sort(saved + [Saved(id: deviceID, lastSeenName: record.lastSeenName)])
    }

    func forget(_ deviceID: String) {
        SecItemDelete(Self.query(deviceID) as CFDictionary)
        saved.removeAll { $0.id == deviceID }
        silent.remove(deviceID)
    }

    /// Proves the token works before keeping it, so a typo fails here rather
    /// than the next time someone tries to use the device.
    func adopt(token: String, for device: DiscoveredDevice) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let endpoint = device.primary?.url else {
            throw EWPError.message("Enter the access token from that device.")
        }
        _ = try await DeviceHTTP.call(url: endpoint, token: trimmed, name: "help",
                                      unreachable: "That device did not answer.")
        try write(Record(token: trimmed, lastSeenName: device.givenName), for: device.id)
    }

    func rename(_ device: DiscoveredDevice, to name: String) async throws {
        guard let stored = record(for: device.id), let endpoint = device.primary?.url else {
            throw EWPError.message("Add this device's access token before renaming it.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= Configuration.nameLimit else {
            throw EWPError.message("A name is limited to \(Configuration.nameLimit) characters.")
        }
        _ = try await DeviceHTTP.call(url: endpoint, token: stored.token, name: "set_name",
                                      arguments: ["name": trimmed],
                                      unreachable: "That device did not accept the name.")
        try write(Record(token: stored.token, lastSeenName: trimmed), for: device.id)
    }

    func identify(_ device: DiscoveredDevice) async throws {
        guard let token = token(for: device.id), let endpoint = device.primary?.url else {
            throw EWPError.message("Add this device's access token first.")
        }
        _ = try await DeviceHTTP.call(url: endpoint, token: token, name: "identify",
                                      arguments: ["seconds": 5],
                                      unreachable: "That device did not answer.")
    }
}
