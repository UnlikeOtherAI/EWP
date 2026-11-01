import Combine
import Foundation
import Network

struct MCPTool {
    let name: String
    let description: String
    var properties: [String: Any] = [:]
    var required: [String] = []
    var schema: [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties,
                         "required": required, "additionalProperties": false]]
    }
}

/// A device-local, stateless Streamable HTTP MCP endpoint. No forwarding service.
@MainActor
final class MCPServer: ObservableObject {
    @Published private(set) var status = "Starting MCP…"
    let port: UInt16
    private let configuration: Configuration
    private let role: String
    private let tools: [MCPTool]
    private let call: (String, [String: Any]) async throws -> [[String: Any]]
    private var listener: NWListener?
    private var listenerID = UUID()
    private var shouldRun = false
    private var retryDelay: Double = 1
    private var retry: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]

    init(configuration: Configuration, role: String, port: UInt16, tools: [MCPTool],
         call: @escaping (String, [String: Any]) async throws -> [[String: Any]]) {
        self.configuration = configuration; self.role = role; self.port = port
        self.tools = tools; self.call = call
    }

    func start() {
        shouldRun = true
        guard listener == nil else { return }
        let generation = UUID(); listenerID = generation
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            var txt = Data()
            for entry in ["path=/mcp", "role=\(role)", "id=\(configuration.deviceID)"] {
                txt.append(UInt8(entry.utf8.count)); txt.append(contentsOf: entry.utf8)
            }
            listener.service = NWListener.Service(name: "EWP \(role) \(configuration.deviceID.prefix(8))",
                                                  type: "_mcp._tcp", domain: "local.", txtRecord: txt)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listenerID == generation else { return }
                    switch state {
                    case .ready: self.status = "MCP ready on port \(self.port)"; self.retryDelay = 1
                    case .waiting(let error): self.status = "MCP unavailable: \(error.localizedDescription)"
                    case .failed(let error):
                        self.status = "MCP unavailable: \(error.localizedDescription)"
                        self.listener?.cancel(); self.listener = nil
                        let delay = self.retryDelay; self.retryDelay = min(30, delay * 2)
                        self.retry?.cancel()
                        self.retry = Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(delay))
                            guard !Task.isCancelled, let self, self.shouldRun else { return }
                            self.start()
                        }
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch { status = error.localizedDescription }
    }

    func stop() {
        shouldRun = false; listenerID = UUID(); retry?.cancel(); retry = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            connection.cancel(); self?.connections.removeValue(forKey: id)
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard buffer.count <= 73728 else { self.reply(connection, id: id, code: 413); return }
                guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 8192 || done || error != nil { self.reply(connection, id: id, code: 400) }
                    else { self.receive(connection, id: id, buffer: buffer) }
                    return
                }
                guard let header = String(data: buffer[..<split.lowerBound], encoding: .utf8) else {
                    self.reply(connection, id: id, code: 400); return
                }
                let lines = header.components(separatedBy: "\r\n")
                let requestLine = lines[0].split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { self.reply(connection, id: id, code: 400); return }
                    let key = line[..<colon].lowercased()
                    guard headers[key] == nil else { self.reply(connection, id: id, code: 400); return }
                    headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard requestLine.count == 3, requestLine[1] == "/mcp" else { self.reply(connection, id: id, code: 404); return }
                guard headers["origin"] == nil else { self.reply(connection, id: id, code: 403); return }
                let supplied = Array((headers["authorization"] ?? "").utf8)
                let expected = Array("Bearer \(self.configuration.token)".utf8)
                var difference = supplied.count ^ expected.count
                for index in expected.indices { difference |= Int(expected[index] ^ (index < supplied.count ? supplied[index] : 0)) }
                guard difference == 0 else { self.reply(connection, id: id, code: 401); return }
                guard requestLine[0] == "POST" else { self.reply(connection, id: id, code: 405); return }
                guard headers["transfer-encoding"] == nil,
                      headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json",
                      let length = Int(headers["content-length"] ?? ""), (1...65536).contains(length) else {
                    self.reply(connection, id: id, code: 400); return
                }
                let body = buffer[split.upperBound...]
                guard body.count >= length else {
                    if done || error != nil { self.reply(connection, id: id, code: 400) }
                    else { self.receive(connection, id: id, buffer: buffer) }
                    return
                }
                guard let request = try? JSONSerialization.jsonObject(with: Data(body.prefix(length))) as? [String: Any],
                      request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
                    self.reply(connection, id: id, code: 200, json: ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid JSON-RPC request"]]); return
                }
                if request["id"] == nil && method.hasPrefix("notifications/") { self.reply(connection, id: id, code: 202); return }
                var response: [String: Any] = ["jsonrpc": "2.0", "id": request["id"] ?? NSNull()]
                switch method {
                case "initialize":
                    response["result"] = ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]],
                                          "serverInfo": ["name": "EWP \(self.role)", "version": "0.2.0"]]
                case "ping": response["result"] = [:] as [String: String]
                case "tools/list": response["result"] = ["tools": self.tools.map(\.schema)]
                case "tools/call":
                    let params = request["params"] as? [String: Any] ?? [:]
                    let name = params["name"] as? String ?? ""
                    guard self.tools.contains(where: { $0.name == name }) else {
                        response["error"] = ["code": -32602, "message": "Unknown tool"]
                        self.reply(connection, id: id, code: 200, json: response); return
                    }
                    do { response["result"] = ["content": try await self.call(name, params["arguments"] as? [String: Any] ?? [:]), "isError": false] }
                    catch { response["result"] = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true] }
                default: response["error"] = ["code": -32601, "message": "Method not found"]
                }
                self.reply(connection, id: id, code: 200, json: response)
            }
        }
    }

    private func reply(_ connection: NWConnection, id: UUID, code: Int, json: [String: Any]? = nil) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let reason = [200:"OK", 202:"Accepted", 400:"Bad Request", 401:"Unauthorized", 403:"Forbidden", 404:"Not Found", 405:"Method Not Allowed", 413:"Payload Too Large"][code] ?? "Error"
        var packet = Data("HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections.removeValue(forKey: id) }
        })
    }

    static func text(_ value: [String: Any]) throws -> [[String: Any]] {
        [["type": "text", "text": String(data: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), encoding: .utf8)!]]
    }
}
