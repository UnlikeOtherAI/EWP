import ReplayKit
import SwiftUI

@main
struct EWPApp: App {
    var body: some Scene { WindowGroup { CompanionView() } }
}

struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        picker.preferredExtension = "com.unlikeotherai.ewp.Broadcast"
        picker.showsMicrophoneButton = false
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct CompanionView: View {
    @StateObject private var discovery = Discovery()
    @StateObject private var provisioning = Provisioning()
    @State private var bridgeAddress = ""
    @State private var token = ""
    @State private var ssid = ""
    @State private var password = ""
    @State private var connected = false
    @State private var active = false
    @State private var message = "Start the local MCP bridge on your computer."
    @State private var working = false
    @AppStorage("installationID") private var installationID = UUID().uuidString

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(active ? "Screen sharing is live" : "Screen sharing is off",
                          systemImage: active ? "record.circle.fill" : "display")
                        .foregroundStyle(active ? .green : .primary)
                    Text("Share this screen with Claude through your local MCP bridge.")
                    HStack {
                        Text("Start screen sharing").font(.headline)
                        Spacer()
                        BroadcastPicker().frame(width: 64, height: 64)
                            .accessibilityLabel("Start screen sharing")
                            .disabled(!connected)
                    }
                    Text("Tap the broadcast icon, then confirm Start Broadcast in Apple's dialog. Stop sharing from the system recording indicator.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("MCP bridge") {
                    ForEach(discovery.services.filter(\.bridge)) { service in
                        Button(service.name) {
                            bridgeAddress = service.url.absoluteString
                            connected = false
                        }
                    }
                    TextField("Bridge URL", text: $bridgeAddress)
                        .textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("bridgeURL")
                    SecureField("Pairing token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("bridgeToken")
                    Button(working ? "Connecting…" : "Connect bridge") { Task { await connectBridge() } }
                        .disabled(working)
                    Text(message).font(.footnote)
                }

                Section("ESP32") {
                    ForEach(discovery.services.filter { !$0.bridge }) { service in
                        Label(service.name, systemImage: "wifi")
                    }
                    ForEach(provisioning.nearby, id: \.identifier) { device in
                        Button(device.name ?? "ESP32") { provisioning.connect(device) }
                    }
                    Text(provisioning.message).font(.footnote)
                    TextField("Wi-Fi name (2.4 GHz)", text: $ssid)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Wi-Fi password", text: $password)
                    Button("Connect ESP32 to Wi-Fi") {
                        do { try provisioning.configure(ssid: ssid, password: password, token: token) }
                        catch { message = error.localizedDescription }
                    }.disabled(!provisioning.ready)
                    Text("First setup: pair using the ESP32's serial-console code. Then open Settings → Bluetooth and pair the ESP32 keyboard. On iPhone, enable AssistiveTouch for pointer control.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = discovery.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Expensive Wall of Phones")
            .task {
                if let config = try? Configuration.load() {
                    bridgeAddress = config.bridge.absoluteString
                    token = config.token
                }
                discovery.start()
                while !Task.isCancelled {
                    if connected { await refreshStatus() }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .onChange(of: discovery.services) { _, services in
                if bridgeAddress.isEmpty, let first = services.first(where: \.bridge) {
                    bridgeAddress = first.url.absoluteString
                }
            }
            .onChange(of: bridgeAddress) { _, _ in connected = false; active = false }
            .onChange(of: token) { _, _ in connected = false; active = false }
        }
    }

    private func connection() throws -> Configuration {
        guard let url = URL(string: bridgeAddress), url.scheme == "http", let host = url.host,
              !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              token.count == 64, token.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw EWPError.message("Choose a local bridge and enter its 64-character pairing token.")
        }
        return Configuration(bridge: url, token: token, deviceID: installationID)
    }

    @MainActor private func connectBridge() async {
        working = true; connected = false; active = false
        defer { working = false }
        do {
            let config = try connection()
            let (_, response) = try await URLSession.shared.data(for: config.request("status"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw EWPError.message("Bridge rejected the connection. Check the pairing token.")
            }
            try config.save()
            connected = true
            message = "Bridge connected. You can start screen sharing."
            await refreshStatus()
        } catch { message = error.localizedDescription }
    }

    @MainActor private func refreshStatus() async {
        do {
            let config = try connection()
            let (data, response) = try await URLSession.shared.data(for: config.request("status"))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let status = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessions = status["sessions"] as? [[String: Any]] else {
                throw EWPError.message("Bridge did not return a valid status.")
            }
            active = sessions.contains { $0["device_id"] as? String == installationID && $0["live"] as? Bool == true }
        } catch { active = false; message = "Bridge unreachable. Check Wi-Fi and reconnect." }
    }
}
