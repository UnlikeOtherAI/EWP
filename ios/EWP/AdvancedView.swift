import SwiftUI

/// Everything the home screen deliberately leaves out, kept one level down and
/// split by subject so that opening Advanced is not its own wall of detail.
struct AdvancedView: View {
    @ObservedObject var model: CompanionModel

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
                            detail: model.discovery.services.isEmpty ? nil : "\(model.discovery.services.count)") {
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
        .background(Color(.systemGroupedBackground))
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
                        Text(detail).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
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
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Subsections

private struct AboutDeviceView: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        DetailScreen(title: "About This Device") {
            Card(caption: "The app endpoint answers MCP requests. The screen endpoint exists only while a broadcast is running.") {
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

    var body: some View {
        DetailScreen(title: "Network") {
            Card(header: "EWP Endpoints",
                 caption: "Every EWP endpoint advertising _mcp._tcp on this Wi-Fi, including this device.") {
                if model.discovery.services.isEmpty {
                    CardRow(divider: true) {
                        HStack(spacing: 10) {
                            if model.discovery.isSearching { ProgressView() }
                            Text(model.discovery.isSearching ? "Looking for devices…" : "No devices found.")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ForEach(model.discovery.services) { service in
                        CardRow(divider: true) {
                            HStack(spacing: 12) {
                                Image(systemName: service.role == "keyboard" ? "keyboard" : "ipad.and.iphone")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(service.name).lineLimit(1)
                                    Text(service.url.absoluteString)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
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
        }
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

extension Bundle {
    var version: String {
        let short = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
