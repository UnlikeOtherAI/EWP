import SwiftUI

/// "Signal": warm ceramic ground, near-black ink, and one vermilion that is
/// spent only on state. A live screen turns the whole top of the page that
/// colour, so it reads from across a room; everything else stays quiet.
enum Theme {
    static let surface = Color(light: 0xF4F2EC, dark: 0x202320)
    static let card = Color(light: 0xFAF9F5, dark: 0x2B2F29)
    static let ink = Color(light: 0x242622, dark: 0xF1EEE5)
    static let subtle = Color(light: 0x777970, dark: 0xADB1A5)
    static let line = Color(light: 0xD5D8CE, dark: 0x484D43)
    static let accent = Color(light: 0xCB3C20, dark: 0xED6A4A)

    /// The live field and the text that sits on it.
    static let live = Color(light: 0xCB3C20, dark: 0xDF5535)
    static let onLive = Color(light: 0xFFF5E9, dark: 0x241E16)
    static let onLiveSecondary = Color(light: 0xFFF0E2, dark: 0x31231B)
    static let onLiveButton = Color(light: 0xFFF5E9, dark: 0x242720)
    static let onLiveButtonLabel = Color(light: 0x963019, dark: 0xF4EEE1)

    /// The same field at rest. Raised rather than coloured, so the colour
    /// means one thing only.
    static let standby = Color(light: 0xE8E8DF, dark: 0x272B26)
    static let standbyLine = Color(light: 0xD2D6C9, dark: 0x3A4038)

    /// Ink-filled control, for the one action in a quiet block.
    static let inkButton = Color(light: 0x242622, dark: 0xE3E6DA)
    static let inkButtonLabel = Color(light: 0xFAF9F5, dark: 0x252B23)

    static let contentWidth: CGFloat = 640
    static let wideContentWidth: CGFloat = 1000
    static let cardRadius: CGFloat = 16
    static let fieldRadius: CGFloat = 20
    static let rowSpacing: CGFloat = 14
    static let cardSpacing: CGFloat = 14
}

extension Color {
    /// One literal per appearance, so a colour is defined where it is chosen
    /// rather than resolved through an asset catalogue entry per shade.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// The mark: three strokes of a wall, the middle one awake.
struct Wordmark: View {
    var body: some View {
        HStack(spacing: 9) {
            HStack(alignment: .bottom, spacing: 2.5) {
                bar(height: 15)
                bar(height: 21)
                bar(height: 15)
            }
            .foregroundStyle(Theme.accent)
            .accessibilityHidden(true)
            Text("EWP")
                .font(.system(size: 29, weight: .heavy))
                .tracking(-1.9)
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("EWP")
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .frame(width: 3.5, height: height)
    }
}

/// A block label: a small outlined square, the title, and whatever state the
/// block wants to report on the right.
struct BlockLabel<Trailing: View>: View {
    let title: String
    var tint: Color = Theme.subtle
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(tint, lineWidth: 1.5)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension BlockLabel where Trailing == EmptyView {
    init(title: String, tint: Color = Theme.subtle) {
        self.init(title: title, tint: tint) { EmptyView() }
    }
}

/// A monospaced state marker: LIVE, STANDBY, WAITING. The lamp breathes only
/// while something is genuinely happening, and never under Reduce Motion.
struct Beacon: View {
    let text: String
    var tint: Color
    var filled = true
    var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wide = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(filled ? tint : .clear)
                    .overlay { if !filled { Circle().stroke(tint, lineWidth: 1) } }
                    .frame(width: 6, height: 6)
                if breathing && !reduceMotion {
                    Circle()
                        .stroke(tint, lineWidth: 1)
                        .frame(width: 14, height: 14)
                        .scaleEffect(wide ? 1.5 : 0.8)
                        .opacity(wide ? 0 : 0.5)
                        .animation(.easeInOut(duration: 1.75).repeatForever(autoreverses: false), value: wide)
                }
            }
            .frame(width: 14, height: 14)
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1)
        }
        .foregroundStyle(tint)
        .onAppear { wide = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text.capitalized)
    }
}

/// A bordered panel. `header` sits inside it, above the content, in the small
/// subtle type the comp uses; `caption` stays outside, under it.
struct Card<Content: View>: View {
    var header: String?
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                if let header {
                    BlockLabel(title: header)
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 2)
                }
                VStack(spacing: 0) { content }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.subtle)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One line inside a panel. Rows separate themselves so callers never place
/// dividers by hand.
struct CardRow<Content: View>: View {
    var divider = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, Theme.rowSpacing)
            if divider {
                Rectangle()
                    .fill(Theme.line)
                    .frame(height: 1)
                    .padding(.leading, 18)
            }
        }
    }
}

/// A label with a right-aligned secondary value.
struct ValueRow: View {
    let label: String
    let value: String
    var monospaced = false
    var divider = true

    var body: some View {
        CardRow(divider: divider) {
            HStack(spacing: 12) {
                Text(label).foregroundStyle(Theme.ink)
                Spacer(minLength: 12)
                Text(value.isEmpty ? "—" : value)
                    .font(monospaced ? .system(size: 14, design: .monospaced) : .system(size: 15))
                    .foregroundStyle(Theme.subtle)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .font(.system(size: 15))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A filled dot that reports a steady state.
struct StatusDot: View {
    let color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if pulsing && !reduceMotion {
                    Circle()
                        .stroke(color, lineWidth: 1.5)
                        .scaleEffect(expanded ? 2.6 : 1)
                        .opacity(expanded ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: expanded)
                }
            }
            .onAppear { expanded = true }
            .accessibilityHidden(true)
    }
}

/// Dot plus label, the compact form used for connection and device state.
struct StatusLabel: View {
    let text: String
    let color: Color
    var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: color, pulsing: pulsing)
            Text(text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// The action inside the live field: a pale slab on the colour.
struct FieldButtonStyle: ButtonStyle {
    var onColour = true

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .tracking(-0.15)
            .foregroundStyle(onColour ? Theme.onLiveButtonLabel : Theme.onLive)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(onColour ? Theme.onLiveButton : Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The one action in a quiet block, filled with ink rather than colour.
struct PrimaryButtonStyle: ButtonStyle {
    var role: ButtonRole?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let fill = role == .destructive ? Theme.accent : Theme.inkButton
        let label = role == .destructive ? Theme.onLive : Theme.inkButtonLabel
        return configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(label)
            .frame(maxWidth: .infinity, minHeight: 45)
            .background(fill.opacity(isEnabled ? 1 : 0.35))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// An outlined action, for anything secondary to the block's own action.
struct SecondaryButtonStyle: ButtonStyle {
    var role: ButtonRole?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let tint = role == .destructive ? Theme.accent : Theme.ink
        return configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.4))
            .frame(maxWidth: .infinity, minHeight: 45)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? Theme.line.opacity(0.5) : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Theme.line, lineWidth: 1)
                    }
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small print under a block: a lock and a sentence, never loose grey text.
struct FinePrint: View {
    let text: String
    var symbol = "lock"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .lineSpacing(2.5)
        .foregroundStyle(Theme.subtle)
    }
}

/// A problem shown where it happened, with the recovery action beside it.
struct InlineError: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        CardRow(divider: false) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let retry {
                        Button("Try Again", action: retry)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }
}

extension View {
    /// Stops content stretching across an iPad, and keeps its leading edge
    /// under the header rather than floating in the middle.
    func readableColumn(wide: Bool = false) -> some View {
        frame(maxWidth: wide ? Theme.wideContentWidth : Theme.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every EWP screen sits on the same ceramic ground.
    func signalBackground() -> some View {
        background(Theme.surface.ignoresSafeArea())
    }
}
