import ReplayKit
import SwiftUI

@main
struct EWPApp: App {
    var body: some Scene { WindowGroup { CompanionView() } }
}

struct BroadcastPicker: UIViewRepresentable {
    let model: CompanionModel
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        picker.preferredExtension = "com.unlikeotherai.ewp.Broadcast"
        picker.showsMicrophoneButton = false
        model.broadcastPicker = picker
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct CompanionView: View {
    @StateObject private var model = CompanionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(model.captureLive ? "Screen sharing is live" : "Screen sharing is off",
                          systemImage: model.captureLive ? "record.circle.fill" : "display")
                        .foregroundStyle(model.captureLive ? .green : .primary)
                    Text("MCP clients connect directly to this device to see its screen.")
                    HStack {
                        Text("Start screen sharing").font(.headline)
                        Spacer()
                        BroadcastPicker(model: model).frame(width: 64, height: 64)
                            .accessibilityLabel("Start screen sharing")
                            .accessibilityIdentifier("startScreenSharing")
                    }
                    Text("Confirm Start Broadcast in Apple's dialog. Screen sharing also has its own MCP endpoint while you use other apps.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("This device") {
                    Label(model.serverStatus, systemImage: "network")
                    Text("Advertised through mDNS. No computer bridge is required.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Copy MCP access token") { model.copyToken() }
                        .accessibilityIdentifier("copyMCPToken")
                }
                Section("ESP32 Wi-Fi setup") {
                    ForEach(model.provisioning.nearby, id: \.identifier) { device in
                        Button(device.name ?? "UnlikeOtherAI keyboard") { model.provisioning.connect(device) }
                    }
                    Text(model.provisioning.message).font(.footnote)
                    TextField("Wi-Fi name (2.4 GHz)", text: $model.ssid)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("wifiSSID")
                    SecureField("Wi-Fi password", text: $model.password)
                        .accessibilityIdentifier("wifiPassword")
                    Button("Connect ESP32 to Wi-Fi") { model.configureWiFi() }
                        .disabled(!model.provisioning.ready)
                    Text("This is a one-time setup. The keyboard keeps its Wi-Fi connection and Bluetooth pairings and runs independently.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("MCP devices on this network") {
                    ForEach(model.discovery.services) { service in
                        VStack(alignment: .leading) {
                            Label(service.name, systemImage: service.role == "keyboard" ? "keyboard" : "display")
                            Text(service.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Find devices again") { model.discovery.restart() }
                    if let error = model.discovery.error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Expensive Wall of Phones")
            .task { await model.run() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.discovery.restart(); model.server?.start() }
            }
        }
    }
}
