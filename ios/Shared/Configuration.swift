import Foundation
import Security

struct Configuration: Codable {
    let token: String
    let deviceID: String

    private static var query: [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "ewp.native-mcp",
                                   kSecAttrAccount as String: "device"]
        if let group = Bundle.main.object(forInfoDictionaryKey: "EWPKeychainGroup") as? String {
            value[kSecAttrAccessGroup as String] = group
        }
        return value
    }

    static func load() throws -> Configuration {
        var query = Self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data else {
            throw EWPError.message("Open EWP once to initialize this device. Keychain status: \(status)")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    static func getOrCreate() throws -> Configuration {
        if let existing = try? load() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw EWPError.message("Could not create the device access token.")
        }
        let value = Configuration(token: bytes.map { String(format: "%02x", $0) }.joined(),
                                  deviceID: UUID().uuidString.lowercased())
        var item = Self.query
        item[kSecValueData as String] = try JSONEncoder().encode(value)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        guard result == errSecSuccess else { throw EWPError.message("Could not save device access: \(result)") }
        return value
    }
}

enum EWPError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
