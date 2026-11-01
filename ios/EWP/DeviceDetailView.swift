import SwiftUI

/// One device on the wall. Naming is the point of this screen: a name lives on
/// the device that owns it, so every client sees the same one, which means
/// renaming needs that device's own access token.
struct DeviceDetailView: View {
    let device: DiscoveredDevice
    @ObservedObject var model: CompanionModel
    @State private var draft = ""
    @State private var token = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var saved = false
    @FocusState private var editing: Bool

    private var hasAccess: Bool { model.remote.hasToken(for: device.id) }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.cardSpacing) {
                if hasAccess { nameCard } else { accessCard }
                detailsCard
                if hasAccess { actionsCard }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
            .readableColumn()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(device.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = device.givenName ?? "" }
    }

    private var nameCard: some View {
        Card(header: "Name", caption: "Stored on the device itself, so every client and every person sees this name.") {
            CardRow(divider: false) {
                HStack(spacing: 12) {
                    TextField("Name this device", text: $draft)
                        .focused($editing)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("deviceName")
                    if busy {
                        ProgressView()
                    } else if saved {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    } else if draft != (device.givenName ?? "") {
                        Button("Save", action: save).font(.body.weight(.semibold))
                    }
                }
            }
            if let problem { InlineError(message: problem) }
        }
        .animation(.easeInOut(duration: 0.2), value: saved)
    }

    private var accessCard: some View {
        Card(header: "Access",
             caption: "Renaming a device means asking it to store the name, so EWP needs the token that device issued. Find it under Advanced → Access on that device, or in its setup output.") {
            CardRow(divider: true) {
                SecureField("Paste its access token", text: $token)
                    .accessibilityIdentifier("remoteToken")
            }
            CardRow(divider: false) {
                HStack(spacing: 12) {
                    Button("Connect", action: adopt)
                        .font(.body.weight(.semibold))
                        .disabled(token.isEmpty || busy)
                    if busy { ProgressView() }
                }
            }
            if let problem { InlineError(message: problem) }
        }
    }

    private var detailsCard: some View {
        Card(header: "Details") {
            ValueRow(label: "Device ID", value: device.id, monospaced: true)
            ValueRow(label: "Provides", value: device.roles.joined(separator: ", "))
            if let firmware = device.firmware {
                ValueRow(label: "Version", value: firmware)
            }
            ForEach(Array(device.endpoints.enumerated()), id: \.element.id) { index, endpoint in
                ValueRow(label: endpoint.role.capitalized, value: endpoint.url.absoluteString,
                         monospaced: true, divider: index < device.endpoints.count - 1)
            }
        }
    }

    private var actionsCard: some View {
        Card(caption: "Identify makes the device announce itself so you can find it on a wall of identical hardware.") {
            CardRow(divider: true) {
                Button {
                    run { try await model.remote.identify(device) }
                } label: {
                    Label("Identify", systemImage: "wave.3.right")
                }
                .disabled(busy)
            }
            CardRow(divider: false) {
                Button(role: .destructive) {
                    model.remote.forget(device.id)
                } label: {
                    Label("Remove Access Token", systemImage: "key.slash")
                }
            }
        }
    }

    private func save() {
        editing = false
        run {
            try await model.remote.rename(device, to: draft)
            saved = true
            model.rescan()
            try? await Task.sleep(for: .seconds(2))
            saved = false
        }
    }

    private func adopt() {
        run {
            try await model.remote.adopt(token: token, for: device)
            token = ""
            draft = device.givenName ?? ""
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        problem = nil
        Task {
            do { try await work() } catch { problem = error.localizedDescription }
            busy = false
        }
    }
}
