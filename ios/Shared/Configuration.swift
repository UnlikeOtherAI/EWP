import Foundation
import Security

struct Configuration: Codable {
    let token: String
    let deviceID: String
    /// Set by a person or an agent. Optional so items written before naming
    /// existed still decode. Lives beside the token because the broadcast
    /// extension advertises it too and the keychain group is what they share.
    var name: String?

    /// What to call this device when it has not been named.
    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? String(deviceID.prefix(8)) : trimmed
    }

    static var query: [String: Any] {
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
                                  deviceID: UUID().uuidString.lowercased(), name: nil)
        var item = Self.query
        item[kSecValueData as String] = try JSONEncoder().encode(value)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        guard result == errSecSuccess else { throw EWPError.message("Could not save device access: \(result)") }
        return value
    }
}

extension Configuration {
    static let nameLimit = 32

    /// Persists a new name and returns the updated configuration.
    @discardableResult
    func renamed(to newName: String) throws -> Configuration {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= Configuration.nameLimit else {
            throw EWPError.message("A name is limited to \(Configuration.nameLimit) characters.")
        }
        var updated = self
        updated.name = trimmed.isEmpty ? nil : trimmed
        let status = SecItemUpdate(Configuration.query as CFDictionary,
                                   [kSecValueData as String: try JSONEncoder().encode(updated)] as CFDictionary)
        guard status == errSecSuccess else { throw EWPError.message("Could not save the name: \(status)") }
        return updated
    }
}

extension Bundle {
    var version: String {
        let short = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

enum EWPError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
