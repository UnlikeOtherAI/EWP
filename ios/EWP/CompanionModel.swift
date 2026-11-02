import Combine
import ReplayKit
import UIKit

/// What the screen-sharing control is doing. The gap between tapping and the
/// first frame belongs to Apple's confirmation dialog, so it gets its own state
/// rather than leaving the button looking inert.
enum SharingPhase: Equatable {
    case off
    case requesting
    case live

    var isBusy: Bool { self == .requesting }
}

/// Whether a client on this Wi-Fi can actually reach this device. "Reachable"
/// is only claimed once the app has resolved its own mDNS advertisement, so the
/// status light reflects the network rather than just a bound socket.
enum Reachability: Equatable {
    case starting
    case verifying
    case reachable(URL)
    case unavailable(String)
}

@MainActor
final class CompanionModel: ObservableObject {
    let discovery = Discovery()
    let provisioning = Provisioning()
    let remote = RemoteDevices()
    @Published var ssid = ""
    @Published var password = ""
    @Published var captureLive = false
    /// What a hardware keyboard has actually sent this device. The other half
    /// of `press_key`: one end reports what went out, this reports what landed.
    let received = ReceivedInput()
    @Published private(set) var sharing: SharingPhase = .off
    @Published var serverStatus = "Starting…"
    @Published private(set) var serverReady = false
    @Published private(set) var tokenCopied = false
    @Published private(set) var promptCopied = false
    @Published private(set) var deviceName = ""
    /// Set while this device is announcing itself so a person can pick it out
    /// of a wall of identical phones.
    @Published private(set) var identifying = false
    @Published var error: String?
    /// Set when this device could not create or read its own access key, which
    /// leaves it unable to serve MCP at all.
    @Published private(set) var setupFailure: String?
    /// What the keyboard board says its physical layout is, once asked. Nil
    /// until it answers, so the picker shows the locale's guess rather than
    /// claiming the board agrees with it.
    @Published private(set) var keyboardLayout: HIDKeyboardLayout?
    @Published private(set) var layoutBusy = false
    @Published var layoutError: String?
    private var configuration: Configuration?
    private var subscriptions = Set<AnyCancellable>()
    private var requestTimeout: Task<Void, Never>?
    private var copyReset: Task<Void, Never>?
    var server: MCPServer?
    weak var broadcastPicker: RPSystemBroadcastPickerView?

    /// The keyboard board's MCP endpoint, with the token this device holds
    /// for it. Both halves are needed and neither is guaranteed: the board
    /// has to be on this network, and someone has to have given this device
    /// its access token in Advanced.
    private func keyboardEndpoint() throws -> (url: URL, token: String) {
        guard let keyboard = discovery.keyboards.first else {
            throw EWPError.message("No keyboard on this network yet.")
        }
        guard let url = keyboard.endpoints.first(where: { $0.role == "keyboard" })?.url
                ?? keyboard.primary?.url else {
            throw EWPError.message("That keyboard did not publish an address.")
        }
        guard let token = remote.token(for: keyboard.id) else {
            throw EWPError.message("Add this keyboard's access token in Advanced first.")
        }
        return (url, token)
    }

    /// Asks the board what layout it is declaring. Quiet on failure: the
    /// picker falls back to the locale's guess, and a board that is not
    /// reachable is not an error worth interrupting setup for.
    func readKeyboardLayout() async {
        guard let (url, token) = try? keyboardEndpoint() else { return }
        guard let result = try? await DeviceHTTP.call(url: url, token: token, name: "device_status"),
              let code = DeviceHTTP.document(result)["keyboard_layout_code"] as? Int,
              let layout = HIDKeyboardLayout.named(UInt8(clamping: code)) else { return }
        keyboardLayout = layout
    }

    func setKeyboardLayout(_ layout: HIDKeyboardLayout) async {
        layoutBusy = true; layoutError = nil
        defer { layoutBusy = false }
        do {
            let (url, token) = try keyboardEndpoint()
            _ = try await DeviceHTTP.call(url: url, token: token, name: "set_layout",
                                          arguments: ["layout": layout.name],
                                          unreachable: "That keyboard did not accept the layout.")
            keyboardLayout = layout
        } catch {
            layoutError = error.localizedDescription
        }
    }

    var deviceID: String { configuration?.deviceID ?? "" }
    var displayName: String { configuration?.displayName ?? "" }
    var serviceName: String { server?.serviceName ?? "" }
    var port: UInt16 { server?.port ?? 7801 }

    init() {
        discovery.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        provisioning.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        remote.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        configure()
    }

    func configure() {
        guard configuration == nil else { return }
        do {
            let configuration = try Configuration.getOrCreate()
            self.configuration = configuration
            deviceName = configuration.name ?? ""
            setupFailure = nil
            let tools = [
                MCPTool(name: "help", description: "Explain what this device is, what it can do, how to reach the keyboard that types on it, and what its results do and do not prove. Call this first."),
                MCPTool(name: "set_name", description: "Give this device a human name. It persists, is published over mDNS, and is how people and agents tell one device on a wall from another.",
                        properties: ["name": ["type": "string", "maxLength": 32]], required: ["name"]),
                MCPTool(name: "identify", description: "Make this device announce itself on screen so a person can find it physically.",
                        properties: ["seconds": ["type": "integer", "minimum": 1, "maximum": 30]], required: []),
                MCPTool(name: "get_status", description: "Read this iPhone/iPad's MCP, screen-sharing and ESP32 setup state."),
                MCPTool(name: "received_input", description: "What a hardware keyboard actually sent this device: HID usage, the modifier bitmask in HID order, the characters produced, and the eight report bytes. This is the other end of the keyboard's press_key, so what was sent can be compared with what arrived. It only sees keys while EWP is in front and holding focus, because iOS delivers key events to no other app; typing into something else is invisible here. Pass clear to start a fresh log.",
                        properties: ["clear": ["type": "boolean"]], required: []),
                MCPTool(name: "get_screen", description: "Get this app's screen, or the shared device screen when a broadcast is live."),
                MCPTool(name: "start_screen_sharing", description: "Open Apple's screen-sharing confirmation on this device. Success means the dialog was requested; check get_status for live frames."),
                MCPTool(name: "stop_screen_sharing", description: "Stop this device's active screen-sharing broadcast."),
                MCPTool(name: "discover_devices", description: "Find native MCP endpoints through mDNS and nearby ESP32 keyboards through Bluetooth."),
                MCPTool(name: "select_esp32", description: "Select a nearby ESP32 for one-time setup without submitting Wi-Fi credentials.",
                        properties: ["bluetooth_id": ["type": "string"]], required: ["bluetooth_id"]),
                MCPTool(name: "configure_esp32", description: "Provision an ESP32 with 2.4 GHz Wi-Fi. Supply ssid and password together, or omit both to submit the form values entered privately in EWP. bluetooth_id defaults to the selected keyboard. The password is never returned.",
                        properties: ["bluetooth_id": ["type": "string"], "ssid": ["type": "string"], "password": ["type": "string"]],
                        required: [])
            ]
            let server = MCPServer(configuration: configuration, role: "app", port: 7801, tools: tools) { [weak self] name, args in
                guard let self else { throw EWPError.message("EWP is closing.") }
                return try await self.call(name, args)
            }
            self.server = server
            server.$status.sink { [weak self] in self?.serverStatus = $0 }.store(in: &subscriptions)
            server.$isReady.sink { [weak self] in self?.serverReady = $0 }.store(in: &subscriptions)
            server.start()
        } catch {
            setupFailure = error.localizedDescription
            self.error = error.localizedDescription
        }
    }

    /// Poll only while the app is on screen. An MCP caller refreshes this state
    /// itself, so nothing depends on the loop having run recently.
    func run() async {
        server?.start(); discovery.start()
        while !Task.isCancelled {
            await refreshCaptureState()
            remote.note(discovery.devices)
            await remote.verify(discovery.devices)
            // Each idle tick is a refused connection to a extension that is not
            // running, so only poll quickly when something is expected to change.
            switch sharing {
            case .requesting: try? await Task.sleep(for: .milliseconds(500))
            case .live: try? await Task.sleep(for: .seconds(2))
            case .off: try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Keeps the device list honest while it is on screen. The home screen's
    /// loop stops when a screen is pushed over it, so a list that shows which
    /// devices are answering has to run its own.
    func watchDevices() async {
        while !Task.isCancelled {
            remote.note(discovery.devices)
            await remote.verify(discovery.devices)
            try? await Task.sleep(for: .seconds(2))
        }
    }

    @discardableResult
    func refreshCaptureState() async -> Bool {
        let live = await screenExtensionIsLive()
        captureLive = live
        if live {
            requestTimeout?.cancel()
            sharing = .live
        } else if sharing == .live {
            sharing = .off
        }
        return live
    }

    private func screenExtensionIsLive() async -> Bool {
        guard let result = try? await DeviceHTTP.call(port: 7802, configuration: configuration, name: "get_status"),
              let content = result["content"] as? [[String: Any]] else { return false }
        for item in content {
            guard let text = item["text"] as? String,
                  let data = text.data(using: .utf8),
                  let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if doc["live"] as? Bool == true { return true }
        }
        return false
    }

    func rescan() { discovery.restart(); provisioning.rescan() }

    var reachability: Reachability {
        if let setupFailure { return .unavailable(setupFailure) }
        if let url = discovery.own(deviceID: deviceID)?.url { return .reachable(url) }
        guard serverReady else {
            return serverStatus.hasPrefix("MCP unavailable") ? .unavailable(serverStatus) : .starting
        }
        return .verifying
    }

    /// Renames this device and re-advertises so the wall sees it at once.
    func rename(to name: String) {
        guard let configuration else { return }
        do {
            let updated = try configuration.renamed(to: name)
            self.configuration = updated
            deviceName = updated.name ?? ""
            server?.rename(to: updated)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func identify(seconds: Int = 3) {
        guard !identifying else { return }
        identifying = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(30, max(1, seconds))))
            self?.identifying = false
        }
    }

    func retry() {
        configure()
        server?.start()
        rescan()
    }

    var endpoint: URL? {
        if case .reachable(let url) = reachability { return url }
        return nil
    }

    /// One thing to hand an agent. The person never has to assemble an address,
    /// a port and a token themselves, and the agent is told where to read more.
    var agentPrompt: String? {
        guard let endpoint, let token = configuration?.token else { return nil }
        return """
        You can see and control my \(UIDevice.current.model), named "\(displayName)", over MCP.

        Add this MCP server:
          URL: \(endpoint.absoluteString)
          Header: Authorization: Bearer \(token)

        Call its `help` tool first. It explains what this device can do, how to
        reach the Bluetooth keyboard that types on it, and how to confirm that
        the input you send actually landed.
        """
    }

    private func help() -> [String: Any] {
        ["device": UIDevice.current.model,
         "name": configuration?.displayName ?? "",
         "id": configuration?.deviceID ?? "",
         "role": "app",
         "summary": "An iPhone or iPad that an MCP client can watch and, with a paired EWP keyboard, control.",
         "getting_started": [
            "Call get_status for this device's screen-sharing state, the keyboards it can see, and the other EWP endpoints on this network.",
            "Call get_screen to see this device. Without a live broadcast it returns the EWP app's own window only.",
            "To see other apps on this device, call start_screen_sharing. A person must then confirm Apple's Start Broadcast dialog in front of the device; nothing is captured until they do. Poll get_status until screen_sharing_live is true.",
            "Typing and clicking happen on a separate endpoint. Browse _mcp._tcp.local. for a service whose role TXT record is 'keyboard', or read mcp_devices from get_status, then call help on it."
         ],
         "important": [
            "Screen capture always requires that visible system confirmation. It cannot be started silently.",
            "A broadcast stops when the person stops it, and get_screen falls back to the app's own window.",
            "Frames are at most 1280 px on the long side, about two per second, and older than five seconds are refused."
         ],
         "setup_tools": "select_esp32 and configure_esp32 are one-time setup helpers for putting a new keyboard board on Wi-Fi. They are not needed to control a device that is already set up."]
    }

    func copyToken() {
        guard let configuration else { return }
        copy(configuration.token) { $0.tokenCopied = $1 }
    }

    func copyPrompt(_ prompt: String) {
        copy(prompt) { $0.promptCopied = $1 }
    }

    private func copy(_ value: String, mark: @escaping (CompanionModel, Bool) -> Void) {
        UIPasteboard.general.string = value
        mark(self, true)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            mark(self, false)
        }
    }

    /// Ask Apple for the broadcast dialog. The system owns the confirmation, so
    /// the app reports that it is waiting rather than claiming sharing started.
    func startSharing() {
        guard sharing == .off else { return }
        do {
            try requestBroadcast()
            sharing = .requesting
            requestTimeout?.cancel()
            requestTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self, self.sharing == .requesting else { return }
                self.sharing = .off
            }
        } catch { self.error = error.localizedDescription }
    }

    func stopSharing() async {
        do {
            _ = try await DeviceHTTP.call(port: 7802, configuration: configuration, name: "stop_screen_sharing")
            sharing = .off
            captureLive = false
        } catch { self.error = error.localizedDescription }
    }

    private func requestBroadcast() throws {
        guard let button = broadcastPicker?.subviews.compactMap({ $0 as? UIButton }).first else {
            throw EWPError.message("Apple's screen-sharing control is unavailable. Bring EWP to the foreground.")
        }
        button.sendActions(for: .touchUpInside)
    }

    func configureWiFi() {
        do {
            try provisioning.configure(ssid: ssid, password: password)
            password = ""; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func status() -> [String: Any] {
        ["device_id": configuration?.deviceID ?? "", "name": configuration?.displayName ?? "",
         "server": serverStatus, "screen_sharing_live": captureLive,
         "screen_mcp_port": 7802, "bluetooth": provisioning.message, "wifi_setup_ready": provisioning.ready, "selected_keyboard": provisioning.selectedBluetoothID ?? "",
         "nearby_keyboards": provisioning.nearby.map { ["bluetooth_id": $0.identifier.uuidString, "name": provisioning.displayName($0)] },
         "mcp_devices": discovery.services.map { ["name": $0.name, "endpoint": $0.url.absoluteString, "role": $0.role] },
         "discovery_error": discovery.error ?? "",
         "bluetooth_state": provisioning.radioState, "bluetooth_scanning": provisioning.scanning]
    }

    private func call(_ name: String, _ args: [String: Any]) async throws -> [[String: Any]] {
        switch name {
        case "help": return try MCPServer.text(help())
        case "set_name":
            guard let name = args["name"] as? String else { throw EWPError.message("Provide a name.") }
            guard let configuration else { throw EWPError.message("This device has no access key yet.") }
            let updated = try configuration.renamed(to: name)
            self.configuration = updated
            deviceName = updated.name ?? ""
            server?.rename(to: updated)
            return try MCPServer.text(["name": updated.displayName, "id": updated.deviceID])
        case "identify":
            identify(seconds: args["seconds"] as? Int ?? 3)
            return try MCPServer.text(["identifying": true, "name": configuration?.displayName ?? ""])
        case "get_status":
            await refreshCaptureState()
            return try MCPServer.text(status())
        case "received_input":
            if args["clear"] as? Bool == true { received.clear() }
            return try MCPServer.text([
                "total_since_launch": received.total,
                "kept": received.presses.count,
                "frontmost_only": "iOS delivers key events only to the app in front; anything typed elsewhere is not here.",
                "entries": received.presses.map { press in
                    [
                        "key": press.label,
                        "usage": press.usage,
                        "modifiers": press.modifiers,
                        "modifier_names": press.modifierNames,
                        "characters": press.characters,
                        "characters_ignoring_modifiers": press.unmodified,
                        "report_bytes": press.reportBytes,
                        "seconds_ago": Int(Date().timeIntervalSince(press.at)),
                    ] as [String: Any]
                },
            ])
        case "discover_devices":
            rescan()
            await refreshCaptureState()
            return try MCPServer.text(status())
        case "start_screen_sharing":
            if await refreshCaptureState() { return try MCPServer.text(["requested": false, "live": true]) }
            try requestBroadcast()
            sharing = .requesting
            return try MCPServer.text(["requested": true, "live": false, "confirmation": "Confirm Start Broadcast in Apple's dialog."])
        case "stop_screen_sharing":
            let result = try await DeviceHTTP.call(port: 7802, configuration: configuration, name: "stop_screen_sharing")
            sharing = .off
            captureLive = false
            return result["content"] as? [[String: Any]] ?? []
        case "get_screen":
            if await refreshCaptureState() {
                let result = try await DeviceHTTP.call(port: 7802, configuration: configuration, name: "get_screen")
                return result["content"] as? [[String: Any]] ?? []
            }
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) else { throw EWPError.message("EWP has no visible window.") }
            let format = UIGraphicsImageRendererFormat()
            // Capture at native resolution, then cap the long side at 1280 px.
            format.scale = min(window.screen.scale, 1280 / max(window.bounds.width, window.bounds.height))
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            guard let data = image.jpegData(compressionQuality: 0.7) else { throw EWPError.message("Could not capture EWP.") }
            return try MCPServer.text(["source": "app", "screen_sharing_live": false]) + [["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"]]
        case "select_esp32":
            guard let id = args["bluetooth_id"] as? String,
                  let device = provisioning.nearby.first(where: { $0.identifier.uuidString == id }) else {
                throw EWPError.message("Choose a nearby keyboard from get_status.")
            }
            provisioning.connect(device)
            return try MCPServer.text(status())
        case "configure_esp32":
            let useForm = args["ssid"] == nil && args["password"] == nil
            guard useForm || (args["ssid"] is String && args["password"] is String) else {
                throw EWPError.message("Provide both Wi-Fi fields, or omit both to submit the app form.")
            }
            let ssid = args["ssid"] as? String ?? self.ssid
            let password = args["password"] as? String ?? self.password
            guard !ssid.isEmpty, ssid.utf8.count <= 32, password.utf8.count <= 64 else {
                throw EWPError.message("Enter the 2.4 GHz Wi-Fi name and password.")
            }
            guard let id = args["bluetooth_id"] as? String ?? provisioning.selectedBluetoothID,
                  let device = provisioning.nearby.first(where: { $0.identifier.uuidString == id }) else {
                throw EWPError.message("Choose a nearby keyboard from get_status and provide its Wi-Fi details.")
            }
            provisioning.connect(device)
            for _ in 0..<40 {
                if provisioning.ready { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard provisioning.ready else { throw EWPError.message(provisioning.message) }
            try provisioning.configure(ssid: ssid, password: password)
            if useForm { self.password = "" }
            return try MCPServer.text(["submitted": true, "state": provisioning.message])
        default: throw EWPError.message("Unknown tool.")
        }
    }
}
