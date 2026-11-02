import SwiftUI

/// Everything the home screen deliberately leaves out, kept one level down and
/// split by subject so that opening Advanced is not its own wall of detail.
struct AdvancedView: View {
    @ObservedObject var model: CompanionModel

    private var otherDevices: [DiscoveredDevice] { model.discovery.others(excluding: model.deviceID) }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.cardSpacing) {
                Card {
                    MenuRow(title: "About This Device", icon: "info.circle") {
                        AboutDeviceView(model: model)
                    }
                    MenuRow(title: "Access", icon: "key") {
                        AccessView(model: model)
                    }
                    MenuRow(title: "Network", icon: "antenna.radiowaves.left.and.right",
                            detail: otherDevices.isEmpty ? nil : "\(otherDevices.count)") {
                        NetworkView(model: model)
                    }
                    MenuRow(title: "Screen Sharing", icon: "rectangle.on.rectangle",
                            detail: model.captureLive ? "Live" : "Off", divider: false) {
                        ScreenSharingView(model: model)
                    }
                }
                if model.error != nil || model.setupFailure != nil {
                    Card {
                        MenuRow(title: "Diagnostics", icon: "stethoscope", tint: .orange, divider: false) {
                            DiagnosticsView(model: model)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
            .readableColumn()
        }
        .signalBackground()
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A row that leads somewhere, with the system's own disclosure behaviour.
private struct MenuRow<Destination: View>: View {
    let title: String
    let icon: String
    var detail: String?
    var tint: Color = Theme.accent
    var divider = true
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            CardRow(divider: divider) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.body)
                        .foregroundStyle(tint)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    Text(title).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if let detail {
                        Text(detail).foregroundStyle(Theme.subtle)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.subtle.opacity(0.65))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}

/// Shared chrome so every Advanced detail screen looks the same.
private struct DetailScreen<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.cardSpacing) { content }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
                .readableColumn()
        }
        .signalBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Subsections

private struct AboutDeviceView: View {
    @ObservedObject var model: CompanionModel
    @State private var draft = ""
    @State private var saved = false
    @FocusState private var editing: Bool

    var body: some View {
        DetailScreen(title: "About This Device") {
            Card(header: "Name",
                 caption: "Published over mDNS, so your agent and anyone browsing the network sees this device by name rather than by its identifier.") {
                CardRow(divider: false) {
                    HStack(spacing: 12) {
                        TextField("Name this device", text: $draft)
                            .focused($editing)
                            .submitLabel(.done)
                            .onSubmit(save)
                            .accessibilityIdentifier("thisDeviceName")
                        if saved {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        } else if draft != model.deviceName {
                            Button("Save", action: save).font(.body.weight(.semibold))
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: saved)
            Card(caption: "The identifier is created once, on first launch, and kept in the keychain, so it survives renaming, restarting and moving to another network. The app endpoint answers MCP requests; the screen endpoint exists only while a broadcast is running.") {
                ValueRow(label: "Device ID", value: model.deviceID, monospaced: true)
                ValueRow(label: "Service", value: model.serviceName)
                ValueRow(label: "App endpoint",
                         value: model.endpoint?.absoluteString ?? "", monospaced: true)
                ValueRow(label: "Screen endpoint", value: "port 7802", monospaced: true, divider: false)
            }
            Card(header: "Version") {
                ValueRow(label: "EWP", value: Bundle.main.version, divider: false)
            }
        }
        .onAppear { draft = model.deviceName }
    }

    private func save() {
        editing = false
        model.rename(to: draft)
        saved = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            saved = false
        }
    }
}

private struct AccessView: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        DetailScreen(title: "Access") {
            Card(caption: "Every EWP device generates its own key and keeps it in the keychain. It is never advertised over mDNS. The agent prompt on the home screen already contains it.") {
                CardRow(divider: false) {
                    Button { model.copyToken() } label: {
                        Label(model.tokenCopied ? "Copied" : "Copy Access Token",
                              systemImage: model.tokenCopied ? "checkmark" : "key")
                            .foregroundStyle(model.tokenCopied ? Color.green : Theme.accent)
                    }
                    .disabled(model.endpoint == nil && model.setupFailure != nil)
                    .accessibilityIdentifier("copyMCPToken")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.tokenCopied)
        }
    }
}

private struct NetworkView: View {
    @ObservedObject var model: CompanionModel

    private var discovered: [DiscoveredDevice] { model.discovery.others(excluding: model.deviceID) }
    private var absent: [RemoteDevices.Saved] { model.remote.absent(from: discovered) }

    /// A saved device that stopped answering belongs in one list, not both.
    private var devices: [DiscoveredDevice] {
        let gone = Set(absent.map(\.id))
        return discovered.filter { !gone.contains($0.id) }
    }

    var body: some View {
        DetailScreen(title: "Network") {
            Card(header: "Other EWP Devices",
                 caption: "This device is not listed; it is under About This Device. A device that advertises more than one endpoint appears once.") {
                if devices.isEmpty {
                    CardRow(divider: true) {
                        HStack(spacing: 10) {
                            if model.discovery.isSearching { ProgressView() }
                            Text(model.discovery.isSearching ? "Looking for devices…" : "No other devices found.")
                                .foregroundStyle(Theme.subtle)
                        }
                    }
                } else {
                    ForEach(devices) { device in
                        NavigationLink {
                            DeviceDetailView(device: device, model: model)
                        } label: {
                            CardRow(divider: true) {
                                HStack(spacing: 12) {
                                    Image(systemName: device.isKeyboard ? "keyboard" : "ipad.and.iphone")
                                        .foregroundStyle(Theme.subtle)
                                        .frame(width: 24)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.title).foregroundStyle(.primary).lineLimit(1)
                                        Text(device.roles.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(Theme.subtle)
                                    }
                                    Spacer(minLength: 8)
                                    if model.remote.hasToken(for: device.id) {
                                        Image(systemName: "key.fill")
                                            .font(.caption)
                                            .foregroundStyle(Theme.subtle.opacity(0.65))
                                            .accessibilityLabel("Access token saved")
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Theme.subtle.opacity(0.65))
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let error = model.discovery.error {
                    InlineError(message: error) { model.rescan() }
                } else {
                    CardRow(divider: false) {
                        Button("Find Devices Again") { model.rescan() }
                            .accessibilityIdentifier("findDevices")
                    }
                }
            }
            if !absent.isEmpty {
                Card(header: "Saved, Not Answering",
                     caption: "Access tokens this device still holds. A device is matched by its identifier, not its name, so renaming one never creates a second entry here \u{2014} but a device whose app was reinstalled comes back with a new identifier, and its old entry stays until you remove it.") {
                    ForEach(absent) { device in
                        CardRow(divider: device.id != absent.last?.id) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.title).foregroundStyle(.primary).lineLimit(1)
                                    Text(device.id)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Theme.subtle)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Button("Remove", role: .destructive) { model.remote.forget(device.id) }
                                    .font(.subheadline)
                                    .accessibilityIdentifier("forget-\(device.id)")
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
        .task { await model.watchDevices() }
    }
}

private struct ScreenSharingView: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        DetailScreen(title: "Screen Sharing") {
            Card(caption: "Apple requires a visible confirmation before any app can record this screen. EWP cannot start capture silently.") {
                CardRow(divider: true) {
                    StatusLabel(text: model.captureLive ? "Live" : "Off",
                                color: model.captureLive ? .red : .secondary,
                                pulsing: model.captureLive)
                }
                ValueRow(label: "Frame rate", value: "2 per second")
                ValueRow(label: "Longest side", value: "1280 px")
                ValueRow(label: "Frames expire after", value: "5 seconds", divider: model.captureLive)
                if model.captureLive {
                    CardRow(divider: false) {
                        Button("Stop Sharing", role: .destructive) { Task { await model.stopSharing() } }
                    }
                }
            }
        }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        DetailScreen(title: "Diagnostics") {
            if let failure = model.setupFailure {
                Card(header: "Device Access",
                     caption: "Without its own key this device cannot serve MCP. Reinstalling EWP usually clears this.") {
                    InlineError(message: failure) { model.retry() }
                }
            }
            Card(header: "MCP Server") {
                ValueRow(label: "Status", value: model.serverStatus, divider: false)
            }
            if let error = model.error {
                Card(header: "Last Error") {
                    InlineError(message: error) { model.error = nil }
                }
            }
        }
    }
}
