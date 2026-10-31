import Foundation

struct Configuration: Codable {
    let bridge: URL
    let token: String
    let deviceID: String

    static let group = "group.com.unlikeotherai.ewp"
    static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("connection.json")
    }

    static func load() throws -> Configuration {
        guard let file else { throw EWPError.message("App Group is unavailable. Check signing.") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    func save() throws {
        guard let file = Self.file else { throw EWPError.message("App Group is unavailable. Check signing.") }
        try JSONEncoder().encode(self).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var url = file
        try url.setResourceValues(resource)
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
