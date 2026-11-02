import CoreBluetooth
import SwiftUI

/// One-time keyboard setup, as a sequence the person can watch. The Wi-Fi
/// fields live here rather than on the home screen: they are needed once, and
/// only once the board is actually listening for them.
struct KeyboardSetupView: View {
    @ObservedObject var model: CompanionModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?

    private enum Field { case ssid, password }

    private var phase: SetupPhase { model.provisioning.phase }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Put the keyboard on the same Wi-Fi as this device. You only do this once.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.subtle)
                        .padding(.bottom, 24)

                    StepView(number: 1, title: "Find the keyboard", state: findState, isLast: false) {
                        findBody
                    }
                    StepView(number: 2, title: "Connect", state: connectState, isLast: false) {
                        if case .failed(let reason) = phase {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(reason).font(.footnote).foregroundStyle(Theme.subtle)
                                Button("Try Again") { model.provisioning.rescan() }
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                    StepView(number: 3, title: "Wi-Fi details", state: detailsState, isLast: false) {
                        if detailsState == .active || detailsState == .busy { wifiFields }
                    }
                    StepView(number: 4, title: "Join Wi-Fi", state: joinState, isLast: true) {
                        if joinState == .busy {
                            Text("Usually under 20 seconds.")
                                .font(.footnote).foregroundStyle(Theme.subtle)
                        }
                    }
                }
                .padding(20)
                .readableColumn()
            }
            .signalBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Set Up Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .connected ? "Done" : "Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if phase == .connected {
                    Button("Done") { dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(16)
                        .background(.bar)
                }
            }
        }
        .onAppear { model.provisioning.rescan() }
    }

    // MARK: Step bodies

    @ViewBuilder private var findBody: some View {
        switch phase {
        case .bluetoothOff:
            Text(phase.message).font(.footnote).foregroundStyle(Theme.subtle)
        case .bluetoothDenied:
            VStack(alignment: .leading, spacing: 10) {
                Text(phase.message).font(.footnote).foregroundStyle(Theme.subtle)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
        case .scanning:
            Text("Make sure the keyboard has power. It accepts setup for five minutes after it starts.")
                .font(.footnote).foregroundStyle(Theme.subtle)
        case .found:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.provisioning.nearby, id: \.identifier) { device in
                    Button {
                        model.provisioning.connect(device)
                    } label: {
                        HStack {
                            Text(model.provisioning.displayName(device))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.subtle.opacity(0.65))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        default:
            if let name = model.provisioning.selectedName {
                Text(name).font(.footnote).foregroundStyle(Theme.subtle)
            }
        }
    }

    private var wifiFields: some View {
        VStack(spacing: 0) {
            TextField("Network name", text: $model.ssid)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .ssid)
                .submitLabel(.next)
                .onSubmit { focus = .password }
                .accessibilityIdentifier("wifiSSID")
                .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().padding(.leading, 14)
            SecureField("Password", text: $model.password)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit(send)
                .accessibilityIdentifier("wifiPassword")
                .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(alignment: .bottom) {
            Text("2.4 GHz networks only.")
                .font(.caption).foregroundStyle(Theme.subtle)
                .offset(y: 20)
        }
        .padding(.bottom, 26)
        .safeAreaInset(edge: .bottom, spacing: 12) {
            Button("Send to Keyboard", action: send)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.ssid.isEmpty || phase != .ready)
                .accessibilityIdentifier("sendWiFi")
        }
    }

    private func send() {
        focus = nil
        model.configureWiFi()
    }

    // MARK: Phase to step state

    private var findState: StepState {
        switch phase {
        case .bluetoothOff, .bluetoothDenied: return .failed
        case .scanning: return .busy
        case .found: return .active
        default: return .done
        }
    }

    private var connectState: StepState {
        switch phase {
        case .bluetoothOff, .bluetoothDenied, .scanning, .found: return .pending
        case .connecting, .preparing: return .busy
        case .failed: return .failed
        default: return .done
        }
    }

    private var detailsState: StepState {
        switch phase {
        case .ready: return .active
        case .setupWindowClosed: return .failed
        case .sending: return .busy
        case .waitingForWiFi, .connected: return .done
        default: return .pending
        }
    }

    private var joinState: StepState {
        switch phase {
        case .waitingForWiFi: return .busy
        case .connected: return .done
        default: return .pending
        }
    }
}

enum StepState { case pending, active, busy, done, failed }

/// A numbered step with a rule connecting it to the next one, so progress
/// through the sequence is visible rather than implied by a changing sentence.
struct StepView<Content: View>: View {
    let number: Int
    let title: String
    let state: StepState
    let isLast: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                marker
                if !isLast {
                    Rectangle()
                        .fill(state == .done ? Theme.accent : Theme.line)
                        .frame(width: 2)
                        .frame(minHeight: 26)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.body.weight(state == .pending ? .regular : .semibold))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                content
            }
            .padding(.bottom, isLast ? 0 : 20)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title), \(describe)")
    }

    private var describe: String {
        switch state {
        case .pending: return "not started"
        case .active: return "waiting for you"
        case .busy: return "in progress"
        case .done: return "done"
        case .failed: return "needs attention"
        }
    }

    @ViewBuilder private var marker: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Theme.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            case .busy:
                ProgressView().scaleEffect(0.8)
            case .failed:
                Circle().fill(Color.orange)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            case .active:
                Circle().strokeBorder(Theme.accent, lineWidth: 2)
            case .pending:
                Circle().strokeBorder(Theme.line, lineWidth: 2)
            }
        }
        .frame(width: 24, height: 24)
    }
}
