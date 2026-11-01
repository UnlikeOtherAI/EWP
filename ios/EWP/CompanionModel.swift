import Combine
import ReplayKit
import UIKit

@MainActor
final class CompanionModel: ObservableObject {
    let discovery = Discovery()
    let provisioning = Provisioning()
    @Published var ssid = ""
    @Published var password = ""
    @Published var captureLive = false
    @Published var serverStatus = "Starting MCP…"
    @Published var error: String?
    private var configuration: Configuration?
    private var subscriptions = Set<AnyCancellable>()
    var server: MCPServer?
    weak var broadcastPicker: RPSystemBroadcastPickerView?

    init() {
        discovery.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        provisioning.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        do {
            let configuration = try Configuration.getOrCreate()
            self.configuration = configuration
            let tools = [
                MCPTool(name: "get_status", description: "Read this iPhone/iPad's MCP, screen-sharing and ESP32 setup state."),
                MCPTool(name: "get_screen", description: "Get this app's screen, or the shared device screen when a broadcast is live."),
                MCPTool(name: "start_screen_sharing", description: "Open Apple's screen-sharing confirmation on this device. Success means the dialog was requested; check get_status for live frames."),
                MCPTool(name: "stop_screen_sharing", description: "Stop this device's active screen-sharing broadcast."),
                MCPTool(name: "discover_devices", description: "Find native MCP endpoints through mDNS and nearby ESP32 keyboards through Bluetooth."),
                MCPTool(name: "configure_esp32", description: "Provision a nearby ESP32 with 2.4 GHz Wi-Fi. It then runs its own MCP server, independently of this app.",
                        properties: ["bluetooth_id": ["type": "string"], "ssid": ["type": "string"], "password": ["type": "string"]],
                        required: ["bluetooth_id", "ssid", "password"])
            ]
            let server = MCPServer(configuration: configuration, role: "app", port: 7801, tools: tools) { [weak self] name, args in
                guard let self else { throw EWPError.message("EWP is closing.") }
                return try await self.call(name, args)
            }
            self.server = server
            server.$status.sink { [weak self] in self?.serverStatus = $0 }.store(in: &subscriptions)
        } catch { self.error = error.localizedDescription }
    }

    func run() async {
        server?.start(); discovery.start()
        while !Task.isCancelled {
            captureLive = (try? await DeviceHTTP.call(port: 7802, configuration: configuration, name: "get_status"))
                .flatMap { $0["content"] as? [[String: Any]] }?
                .contains { ($0["text"] as? String)?.contains("\"live\":true") == true } ?? false
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func copyToken() { if let configuration { UIPasteboard.general.string = configuration.token } }

    func configureWiFi() {
        do {
            guard let configuration else { throw EWPError.message("Device access is unavailable.") }
            try provisioning.configure(ssid: ssid, password: password, token: configuration.token)
            password = ""; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func status() -> [String: Any] {
        ["device_id": configuration?.deviceID ?? "", "server": serverStatus, "screen_sharing_live": captureLive,
         "screen_mcp_port": 7802, "bluetooth": provisioning.message, "wifi_setup_ready": provisioning.ready,
         "nearby_keyboards": provisioning.nearby.map { ["bluetooth_id": $0.identifier.uuidString, "name": $0.name ?? "ESP32"] },
         "mcp_devices": discovery.services.map { ["name": $0.name, "endpoint": $0.url.absoluteString, "role": $0.role] },
         "discovery_error": discovery.error ?? ""]
    }

    private func call(_ name: String, _ args: [String: Any]) async throws -> [[String: Any]] {
        switch name {
        case "get_status": return try MCPServer.text(status())
        case "discover_devices": discovery.restart(); return try MCPServer.text(status())
        case "start_screen_sharing":
            guard let button = broadcastPicker?.subviews.compactMap({ $0 as? UIButton }).first else {
                throw EWPError.message("Apple's screen-sharing control is unavailable. Bring EWP to the foreground.")
            }
            button.sendActions(for: .touchUpInside)
            return try MCPServer.text(["requested": true, "live": false, "confirmation": "Confirm Start Broadcast in Apple's dialog."])
        case "stop_screen_sharing":
            let result = try await DeviceHTTP.call(port: 7802, configuration: configuration, name: "stop_screen_sharing")
            return result["content"] as? [[String: Any]] ?? []
        case "get_screen":
            if captureLive, let result = try? await DeviceHTTP.call(port: 7802, configuration: configuration, name: "get_screen") {
                return result["content"] as? [[String: Any]] ?? []
            }
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) else { throw EWPError.message("EWP has no visible window.") }
            let format = UIGraphicsImageRendererFormat(); format.scale = min(1, 1280 / max(window.bounds.width, window.bounds.height))
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            guard let data = image.jpegData(compressionQuality: 0.7) else { throw EWPError.message("Could not capture EWP.") }
            return [["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"]]
        case "configure_esp32":
            guard let id = args["bluetooth_id"] as? String, let ssid = args["ssid"] as? String,
                  let password = args["password"] as? String, let configuration,
                  let device = provisioning.nearby.first(where: { $0.identifier.uuidString == id }) else {
                throw EWPError.message("Choose a nearby keyboard from get_status and provide its Wi-Fi details.")
            }
            provisioning.connect(device)
            for _ in 0..<40 {
                if provisioning.ready { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard provisioning.ready else { throw EWPError.message(provisioning.message) }
            try provisioning.configure(ssid: ssid, password: password, token: configuration.token)
            return try MCPServer.text(["submitted": true, "state": provisioning.message])
        default: throw EWPError.message("Unknown tool.")
        }
    }
}
