import SwiftUI

/// The home screen answers three questions and nothing else: is my screen being
/// shared, can my agent reach this device, and is a keyboard attached. Ports,
/// tokens, addresses and the raw device list live in Advanced.
struct CompanionView: View {
    @StateObject private var model = CompanionModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSetup = false
    @State private var poll: Task<Void, Never>?

    /// One poll at a time, however often the view appears.
    private func startPolling() {
        poll?.cancel()
        poll = Task { await model.run() }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let layout = Layout(size: geometry.size)
                ScrollView {
                    VStack(spacing: Theme.cardSpacing) {
                        header
                        // Short content sits in the middle of the space left
                        // under the wordmark rather than against the top with
                        // the rest of the screen blank: on an iPad that blank
                        // was half the display. The cards keep their own
                        // height, so the slack goes to the spacers and not
                        // into stretching the field past the size it asked for.
                        Spacer(minLength: 0)
                        cards(layout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: geometry.size.height - 48, alignment: .top)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                    .readableColumn(wide: layout.twoColumn)
                }
            }
            .background(KeyCatcher(log: model.received).frame(width: 0, height: 0))
            .signalBackground()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { model.rescan() }
            .sheet(isPresented: $showSetup) { KeyboardSetupView(model: model) }
            .overlay { if model.identifying { IdentifyFlash(name: model.displayName) } }
        }
        .tint(Theme.accent)
        .task { startPolling() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.server?.start()
                model.rescan()
                startPolling()
            case .background:
                // Nothing on screen to update, and an MCP caller refreshes state itself.
                poll?.cancel(); poll = nil
            default: break
            }
        }
    }

    @ViewBuilder
    private func cards(_ layout: Layout) -> some View {
        VStack(spacing: Theme.cardSpacing) {
            switch layout.shape {
            case .beside:
                // Equal explicit widths: left to negotiate, the columns size
                // to their text and long messages get truncated.
                HStack(alignment: .top, spacing: Theme.cardSpacing) {
                    ShareField(model: model, layout: layout)
                        .frame(maxWidth: .infinity)
                    VStack(spacing: Theme.cardSpacing) {
                        AgentBlock(model: model)
                        KeyboardBlock(model: model, showSetup: $showSetup)
                    }
                    .frame(maxWidth: .infinity)
                }
            case .below:
                ShareField(model: model, layout: layout)
                HStack(alignment: .top, spacing: Theme.cardSpacing) {
                    AgentBlock(model: model).frame(maxWidth: .infinity)
                    KeyboardBlock(model: model, showSetup: $showSetup)
                        .frame(maxWidth: .infinity)
                }
            case .stacked:
                ShareField(model: model, layout: layout)
                AgentBlock(model: model)
                KeyboardBlock(model: model, showSetup: $showSetup)
            }
        }
    }

    /// The app's own header, rather than a system large title: the wordmark is
    /// heavier and tighter than any system style, and it is half the identity.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Wordmark()
            Spacer(minLength: 12)
            NavigationLink { AdvancedView(model: model) } label: {
                HStack(spacing: 6) {
                    Text("Advanced")
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                }
                .font(.system(size: 14))
                .foregroundStyle(Theme.subtle)
            }
            .accessibilityIdentifier("advanced")
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

/// The home screen is laid out from the space it is actually given, not from
/// the size class. An iPad in a narrow split is a phone; an iPhone Duo folded
/// shut is a phone and opened out is a short wide screen, and no size class
/// tells them apart; and a phone in landscape has less height than the field
/// alone would like.
struct Layout {
    /// Where the two quiet blocks go relative to the field.
    enum Shape {
        /// One column, the blocks under the field. Any phone.
        case stacked
        /// The blocks beside the field. A screen wide enough for two
        /// readable measures and too short to put anything under them.
        case beside
        /// The blocks side by side in a row under a full-width field. A wide
        /// screen that is also tall: beside the field there, the field would
        /// have to be a tower to fill the height, and anything shorter leaves
        /// the bottom half of the screen empty.
        case below
    }

    let shape: Shape
    let fieldHeight: CGFloat
    let padding: CGFloat
    /// Applied to the headline, which is the one thing that cannot simply
    /// wrap its way out of a narrow column.
    let titleScale: CGFloat

    var twoColumn: Bool { shape != .stacked }

    init(size: CGSize) {
        // Two readable measures side by side, plus the gutter between them.
        // 700 rather than 620: an iPhone Duo is 669 pt across its larger
        // screen, and splitting that leaves two columns narrower than a
        // phone's, which reads worse than one column and a scroll.
        let wide = size.width >= 700
        // A screen taller than it is wide has room under the field for the
        // blocks, and needs it: an iPad Air in portrait is 1032 x 1376, and
        // beside the field that left half the display blank.
        shape = wide ? (size.height > size.width ? .below : .beside) : .stacked
        padding = wide ? 26 : 22
        // Splitting a 678 pt screen leaves columns narrower than a phone's,
        // so the headline comes down with them rather than overflowing.
        let column = shape == .beside ? (size.width - 46) / 2 : size.width - 32
        titleScale = column < 330 ? 0.78 : 1

        // The field is bounded by its own width as well as by the space left
        // over, because the shared screen appears in it and a card far taller
        // than it is wide is a void with a button at the bottom.
        let ceiling: CGFloat
        let room: CGFloat
        switch shape {
        case .stacked:
            ceiling = 348
            // The blocks under it have to stay in sight without scrolling.
            room = size.height - 360
        case .beside:
            ceiling = column * 1.25
            room = size.height - 90
        case .below:
            ceiling = column * 0.8
            // Header, the row of blocks under the field, and the gaps.
            room = size.height - 330
        }
        fieldHeight = min(ceiling, max(236, room))
    }
}

// MARK: - Screen sharing

/// The one block that is allowed to use the colour, and only when live.
private struct ShareField: View {
    @ObservedObject var model: CompanionModel
    var layout: Layout
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 44

    private var live: Bool { model.sharing == .live }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BlockLabel(title: "Screen sharing", tint: labelTint) { beacon }
            Text(title)
                .font(.system(size: titleSize * layout.titleScale, weight: .semibold))
                .tracking(-1.9)
                .foregroundStyle(live ? Theme.onLive : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                // A long word in a narrow column, or a large accessibility
                // size, shrinks the headline instead of clipping it.
                .minimumScaleFactor(0.6)
                // Held to a measure so it breaks into two lines rather than
                // running the width of the field as one thin headline.
                .frame(maxWidth: layout.twoColumn ? .infinity : (live ? 350 : 300), alignment: .leading)
                .padding(.top, 18)
            Text(detail)
                .font(.system(size: 15.5))
                .lineSpacing(4)
                .foregroundStyle(live ? Theme.onLiveSecondary : Theme.subtle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330, alignment: .leading)
                .padding(.top, 10)
            if live {
                facts.padding(.top, 16)
                Spacer(minLength: 24)
            } else {
                Spacer(minLength: 16)
                emblem
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 6)
                Spacer(minLength: 16)
            }
            action
        }
        .padding(layout.padding)
        .frame(maxWidth: .infinity, minHeight: layout.fieldHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
                .fill(live ? Theme.live : Theme.standby)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
                        .stroke(live ? .clear : Theme.standbyLine, lineWidth: 1)
                }
        }
        .broadcastTrigger(model)
        .animation(.easeInOut(duration: 0.3), value: model.sharing)
    }

    private var labelTint: Color { live ? Theme.onLiveSecondary : Theme.subtle }

    /// The field at rest still shows the thing it will become: a broadcast
    /// mark on a dormant key, outlined rather than filled.
    private var emblem: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(Theme.subtle.opacity(0.7))
            .frame(width: 74, height: 60)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface.opacity(0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.standbyLine, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var beacon: some View {
        switch model.sharing {
        case .off: Beacon(text: "STANDBY", tint: Theme.subtle, filled: false)
        case .requesting: Beacon(text: "WAITING", tint: Theme.subtle, breathing: true)
        case .live: Beacon(text: "LIVE", tint: Theme.onLive, breathing: true)
        }
    }

    /// What is actually leaving the device, stated plainly on the field.
    private var facts: some View {
        HStack(spacing: 14) {
            Text("2 frames per second")
            Rectangle().fill(Theme.onLive.opacity(0.45)).frame(width: 1, height: 12)
            Text("1280 px")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.onLive)
        .accessibilityElement(children: .combine)
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
                .buttonStyle(FieldButtonStyle(onColour: false))
                .accessibilityIdentifier("startScreenSharing")
        case .requesting:
            FinePrint(text: "Apple asks before any app can record this screen.",
                      symbol: "hand.raised")
        case .live:
            Button("Stop Sharing") { Task { await model.stopSharing() } }
                .buttonStyle(FieldButtonStyle())
                .accessibilityIdentifier("stopScreenSharing")
        }
    }
}

// MARK: - Your agent

private struct AgentBlock: View {
    @ObservedObject var model: CompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BlockLabel(title: "Your agent") { reachability }
            state.padding(.top, 8)
            if let prompt = model.agentPrompt {
                Button { model.copyPrompt(prompt) } label: {
                    Label(model.promptCopied ? "Copied" : "Copy Agent Prompt",
                          systemImage: model.promptCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("copyAgentPrompt")
                .padding(.top, 14)
                ShareLink(item: prompt) {
                    HStack(spacing: 6) {
                        Text("Send to Another Device")
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                FinePrint(text: "Contains this device's access key. Give it to your own agent and no one else.")
                    .padding(.top, 4)
            } else {
                FinePrint(text: "Everything your agent needs appears here once this device is on the network.",
                          symbol: "antenna.radiowaves.left.and.right")
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .stroke(Theme.line, lineWidth: 1)
                }
        }
        .animation(.easeInOut(duration: 0.2), value: model.promptCopied)
    }

    @ViewBuilder private var reachability: some View {
        switch model.reachability {
        case .starting, .verifying:
            Beacon(text: "CHECKING", tint: Theme.subtle, breathing: true)
        case .reachable:
            Beacon(text: "REACHABLE", tint: Theme.accent)
        case .unavailable:
            Beacon(text: "OFFLINE", tint: Theme.subtle, filled: false)
        }
    }

    @ViewBuilder private var state: some View {
        switch model.reachability {
        case .starting, .verifying:
            headline("Checking the network…")
        case .reachable:
            headline("Ready for your agent")
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 8) {
                headline("Not reachable")
                // Without this a narrow column truncates instead of wrapping.
                Text(reason)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { model.retry() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 21, weight: .semibold))
            .tracking(-0.6)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Keyboard

private struct KeyboardBlock: View {
    @ObservedObject var model: CompanionModel
    @Binding var showSetup: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let keyboard = model.discovery.keyboards.first {
                // Tapping it reopens setup: a board moved to a different
                // network is the one reason to come back to this flow.
                Button { showSetup = true } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Keyboard")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.subtle)
                            HStack(spacing: 10) {
                                Text(keyboard.title)
                                    .font(.system(size: 19, weight: .semibold))
                                    .tracking(-0.4)
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                StatusLabel(text: "On this network", color: Theme.accent)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.subtle)
                            }
                        }
                        Spacer(minLength: 8)
                        glyph
                    }
                    // A plain button only accepts taps on what it draws,
                    // and most of this row is spacer.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("keyboardDetail")
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Keyboard")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.subtle)
                        Text("No keyboard yet")
                            .font(.system(size: 19, weight: .semibold))
                            .tracking(-0.4)
                            .foregroundStyle(Theme.ink)
                    }
                    Spacer(minLength: 8)
                    glyph
                }
                Text("A keyboard board lets your agent type and click on this device, not just watch it.")
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up Keyboard") { showSetup = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("setUpKeyboard")
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        }
    }

    /// The board itself, drawn as a key cap rather than a list icon.
    private var glyph: some View {
        Image(systemName: "keyboard")
            .font(.system(size: 17))
            .foregroundStyle(Theme.accent)
            .frame(width: 42, height: 34)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.line, lineWidth: 1)
                    }
            }
            .accessibilityHidden(true)
    }
}

/// What `identify` looks like: this device shouting its name across a room of
/// identical hardware.
private struct IdentifyFlash: View {
    let name: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        ZStack {
            Theme.live
            Text(name)
                .font(.system(size: 64, weight: .heavy))
                .tracking(-2)
                .minimumScaleFactor(0.3)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.onLive)
                .padding(40)
        }
        .ignoresSafeArea()
        .opacity(bright || reduceMotion ? 1 : 0.55)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: bright)
        .onAppear { bright = true }
        .transition(.opacity)
        .accessibilityLabel("This device is \(name)")
    }
}
