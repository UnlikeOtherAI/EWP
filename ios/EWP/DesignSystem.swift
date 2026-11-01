import SwiftUI

/// Shared look for every EWP screen: one accent, system-semantic colours for
/// meaning, and grouped-inset cards sized for both iPhone and iPad.
enum Theme {
    /// Matches the AccentColor asset so system controls and custom views agree.
    static let accent = Color("AccentColor")
    /// iPad and large iPhones keep a readable measure instead of stretching.
    static let contentWidth: CGFloat = 640
    static let cardRadius: CGFloat = 16
    static let rowSpacing: CGFloat = 14
    static let cardSpacing: CGFloat = 18
}

/// A grouped-inset card with an optional header above it and caption below,
/// matching the spacing Settings uses for its sections.
struct Card<Content: View>: View {
    var header: String?
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let header {
                Text(header)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .padding(.horizontal, 16)
            }
            VStack(spacing: 0) { content }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// One line inside a card. Rows separate themselves with an inset hairline so
/// callers never place dividers by hand.
struct CardRow<Content: View>: View {
    var divider = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, Theme.rowSpacing)
            if divider {
                Divider().padding(.leading, 16)
            }
        }
    }
}

/// A label with a right-aligned secondary value, as used throughout Settings.
struct ValueRow: View {
    let label: String
    let value: String
    var monospaced = false
    var divider = true

    var body: some View {
        CardRow(divider: divider) {
            HStack(spacing: 12) {
                Text(label)
                Spacer(minLength: 12)
                Text(value.isEmpty ? "—" : value)
                    .font(monospaced ? .body.monospaced() : .body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A filled dot that reports a steady state. `pulsing` is reserved for states
/// that are genuinely changing, and honours Reduce Motion.
struct StatusDot: View {
    let color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay {
                if pulsing && !reduceMotion {
                    Circle()
                        .stroke(color, lineWidth: 2)
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
        HStack(spacing: 9) {
            StatusDot(color: color, pulsing: pulsing)
            Text(text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var role: ButtonRole?
    @Environment(\.isEnabled) private var isEnabled

    private var tint: Color { role == .destructive ? .red : Theme.accent }

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(isEnabled ? 1 : 0.4))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var role: ButtonRole?
    @Environment(\.isEnabled) private var isEnabled

    private var tint: Color { role == .destructive ? .red : Theme.accent }

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.4))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(configuration.isPressed ? 0.22 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A problem shown where it happened, with the recovery action beside it,
/// rather than as loose red text at the end of the screen.
struct InlineError: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        CardRow(divider: false) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.subheadline)
                    if let retry {
                        Button("Try Again", action: retry)
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }
}

extension View {
    /// Stops content stretching across an iPad, and keeps its leading edge
    /// under the navigation title rather than floating in the middle.
    func readableColumn() -> some View {
        frame(maxWidth: Theme.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
