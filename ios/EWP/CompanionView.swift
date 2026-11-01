import SwiftUI

/// The home screen answers three questions and nothing else: is my screen being
/// shared, can my agent reach this device, and is a keyboard attached. Ports,
/// tokens, addresses and the raw device list live in Advanced.
struct CompanionView: View {
    @StateObject private var model = CompanionModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSetup = false
    @State private var poll: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.cardSpacing) {
                    SharingCard(model: model)
                    ConnectionCard(model: model)
                    KeyboardCard(model: model, showSetup: $showSetup)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
                .readableColumn()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("EWP")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Advanced") { AdvancedView(model: model) }
                        .accessibilityIdentifier("advanced")
                }
            }
            .refreshable { model.rescan() }
            .sheet(isPresented: $showSetup) { KeyboardSetupView(model: model) }
        }
        .task { poll = Task { await model.run() }; await poll?.value }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.server?.start()
                model.rescan()
                if poll == nil || poll?.isCancelled == true { poll = Task { await model.run() } }
            case .background:
                // Nothing on screen to update, and an MCP caller refreshes state itself.
                poll?.cancel(); poll = nil
            default: break
            }
        }
    }
}

// MARK: - Screen sharing

private struct SharingCard: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        Card {
            VStack(spacing: 14) {
                emblem
                VStack(spacing: 5) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                action
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .broadcastTrigger(model)
        .animation(.easeInOut(duration: 0.25), value: model.sharing)
    }

    @ViewBuilder private var emblem: some View {
        ZStack {
            Circle()
                .fill(model.sharing == .live ? Color.red.opacity(0.12) : Color(.tertiarySystemFill))
                .frame(width: 60, height: 60)
            switch model.sharing {
            case .off:
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.secondary)
            case .requesting:
                ProgressView()
            case .live:
                StatusDot(color: .red, pulsing: true).scaleEffect(1.6)
            }
        }
        .accessibilityHidden(true)
    }

    private var title: String {
        switch model.sharing {
        case .off: return "Ready to share"
        case .requesting: return "Waiting for you to confirm"
        case .live: return "Screen sharing is live"
        }
    }

    private var detail: String {
        switch model.sharing {
        case .off: return "Nothing is being shared yet."
        case .requesting: return "Choose EWP Screen Sharing, then tap Start Broadcast."
        case .live: return "Your agent can see this screen, even while you use other apps."
        }
    }

    @ViewBuilder private var action: some View {
        switch model.sharing {
        case .off:
            Button("Start Screen Sharing") { model.startSharing() }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("startScreenSharing")
        case .requesting:
            Text("Apple asks before any app can record this screen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .live:
            Button("Stop Sharing") { Task { await model.stopSharing() } }
                .buttonStyle(SecondaryButtonStyle(role: .destructive))
                .accessibilityIdentifier("stopScreenSharing")
        }
    }
}

// MARK: - Connection

private struct ConnectionCard: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        Card(header: "Your Agent", caption: caption) {
            CardRow(divider: model.agentPrompt != nil) { state }
            if let prompt = model.agentPrompt {
                CardRow(divider: true) {
                    Button { model.copyPrompt(prompt) } label: {
                        Label(model.promptCopied ? "Copied" : "Copy Agent Prompt",
                              systemImage: model.promptCopied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(model.promptCopied ? Color.green : Theme.accent)
                    }
                    .accessibilityIdentifier("copyAgentPrompt")
                }
                CardRow(divider: false) {
                    ShareLink(item: prompt) {
                        Label("Send to Another Device", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.promptCopied)
    }

    private var caption: String {
        model.agentPrompt == nil
            ? "Everything your agent needs will appear here once this device is on the network."
            : "Contains this device's access key. Give it to your own agent and no one else."
    }

    @ViewBuilder private var state: some View {
        switch model.reachability {
        case .starting:
            HStack(spacing: 10) { ProgressView(); Text("Starting…").foregroundStyle(.secondary) }
        case .verifying:
            HStack(spacing: 10) { ProgressView(); Text("Checking the network…").foregroundStyle(.secondary) }
        case .reachable:
            StatusLabel(text: "Ready for your agent", color: .green)
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 8) {
                StatusLabel(text: "Not reachable", color: .orange)
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                Button("Try Again") { model.retry() }
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

// MARK: - Keyboard

private struct KeyboardCard: View {
    @ObservedObject var model: CompanionModel
    @Binding var showSetup: Bool

    var body: some View {
        Card(header: "Keyboard", caption: caption) {
            if let keyboard = model.discovery.keyboards.first {
                // Tapping it reopens setup: a board moved to a different
                // network is the one reason to come back to this flow.
                CardRow(divider: false) {
                    Button { showSetup = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "keyboard")
                                .font(.title3)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(keyboard.name).foregroundStyle(.primary).lineLimit(1)
                                StatusLabel(text: "On this network", color: .green)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        // A plain button only accepts taps on what it draws,
                        // and most of this row is spacer.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("keyboardDetail")
                }
            } else {
                CardRow(divider: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "keyboard")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            Text("No keyboard yet")
                        }
                        Button("Set Up Keyboard") { showSetup = true }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("setUpKeyboard")
                    }
                }
            }
        }
    }

    private var caption: String {
        model.discovery.keyboards.isEmpty
            ? "A keyboard board lets your agent type and click on this device, not just watch it."
            : "To let it type here, pair it with this device in Settings → Bluetooth."
    }
}
