import Foundation

/// Pairing tokens and screen frames must never follow an HTTP redirect off the LAN.
final class DeviceHTTP: NSObject, URLSessionTaskDelegate {
    static let shared = DeviceHTTP()
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    @MainActor static func call(port: UInt16, configuration: Configuration?, name: String) async throws -> [String: Any] {
        guard let configuration else { throw EWPError.message("Open EWP first.") }
        return try await call(url: URL(string: "http://127.0.0.1:\(port)/mcp")!,
                              token: configuration.token, name: name, timeout: 2,
                              unreachable: "Screen-sharing MCP is not running.")
    }

    /// Calls one MCP tool on any EWP endpoint, local or on another device.
    static func call(url: URL, token: String, name: String, arguments: [String: Any] = [:],
                     timeout: TimeInterval = 5,
                     unreachable: String = "That device did not answer.") async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]])
        let (data, response) = try await shared.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code != 401 else { throw EWPError.message("That access token was refused.") }
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else { throw EWPError.message(unreachable) }
        if result["isError"] as? Bool == true {
            let content = result["content"] as? [[String: Any]]
            throw EWPError.message(content?.first?["text"] as? String ?? unreachable)
        }
        return result
    }

    /// The first JSON object in a tool result's text content.
    static func document(_ result: [String: Any]) -> [String: Any] {
        for item in result["content"] as? [[String: Any]] ?? [] {
            guard let text = item["text"] as? String, let data = text.data(using: .utf8),
                  let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return doc
        }
        return [:]
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
