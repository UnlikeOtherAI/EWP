import Foundation
import Security

struct Configuration: Codable {
    let bridge: URL
    let token: String
    let deviceID: String

    private static var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "ewp.connection",
                                   kSecAttrAccount as String: "local-bridge"]
        if let group = Bundle.main.object(forInfoDictionaryKey: "EWPKeychainGroup") as? String {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    static func load() throws -> Configuration {
        var query = Self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        guard result == errSecSuccess, let data = value as? Data else {
            throw EWPError.message("Connect the local bridge in EWP first. Keychain status: \(result)")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(self),
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(Self.query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            let item = Self.query.merging(attributes) { _, value in value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw EWPError.message("Cannot save bridge connection: \(added)") }
        } else if result != errSecSuccess {
            throw EWPError.message("Cannot update bridge connection: \(result)")
        }
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json") -> URLRequest {
        var request = URLRequest(url: bridge.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 4
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }
}

enum EWPError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
