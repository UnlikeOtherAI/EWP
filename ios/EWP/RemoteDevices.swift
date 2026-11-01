import Foundation
import Security

/// Access to EWP devices other than this one. Each device issues its own
/// token, so renaming one means holding its token; tokens are kept in the
/// keychain, never in defaults and never shown after they are entered.
@MainActor
final class RemoteDevices: ObservableObject {
    @Published private(set) var known: Set<String> = []

    init() { known = Self.storedIdentifiers() }

    private static let service = "ewp.remote-device"

    private static func query(_ deviceID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: deviceID]
    }

    private static func storedIdentifiers() -> Set<String> {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true]
        query[kSecReturnData as String] = false
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let items = value as? [[String: Any]] else { return [] }
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    func token(for deviceID: String) -> String? {
        var query = Self.query(deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasToken(for deviceID: String) -> Bool { known.contains(deviceID) }

    private func store(_ token: String, for deviceID: String) throws {
        let data = Data(token.utf8)
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
        known.insert(deviceID)
    }

    func forget(_ deviceID: String) {
        SecItemDelete(Self.query(deviceID) as CFDictionary)
        known.remove(deviceID)
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
        try store(trimmed, for: device.id)
    }

    func rename(_ device: DiscoveredDevice, to name: String) async throws {
        guard let token = token(for: device.id), let endpoint = device.primary?.url else {
            throw EWPError.message("Add this device's access token before renaming it.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= Configuration.nameLimit else {
            throw EWPError.message("A name is limited to \(Configuration.nameLimit) characters.")
        }
        _ = try await DeviceHTTP.call(url: endpoint, token: token, name: "set_name",
                                      arguments: ["name": trimmed],
                                      unreachable: "That device did not accept the name.")
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
