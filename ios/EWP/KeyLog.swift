import SwiftUI

/// What came through the keyboard, as a person reads it rather than as a
/// machine does. `received_input` serves the same presses over MCP with every
/// field intact; this is the view for whoever is holding the device.
///
/// It is a console, and looks like one: green on charcoal, monospaced, the one
/// surface in EWP that does not follow the light or dark appearance. That is
/// deliberate rather than decorative — a log of keystrokes is read the way a
/// terminal is read, in long stretches, and the usual card gives no signal
/// that what is inside is machine output rather than prose.
///
/// Presses are gathered into runs rather than listed one per line. A line of
/// typing is one event to a person, not forty, and timestamping every letter
/// buries the thing you are looking for. A run ends at a newline, at a key
/// that is not a character, or after a pause, and carries the time it began.
struct KeyLogView: View {
    @ObservedObject var log: ReceivedInput
    /// How tall the console should be at least. Applied inside the card, so
    /// the charcoal grows with it; outside, it only adds empty page around a
    /// card that stays the size of its text.
    var minHeight: CGFloat = 0

    /// A run of presses that belong together.
    struct Run: Identifiable {
        let id = UUID()
        let began: Date
        var text: String = ""
        /// Keys with no printable character of their own, in the order they
        /// arrived: Tab, Escape, the arrows, anything with Command held.
        var specials: [String] = []
        var count = 0
    }

    /// Longer than this between presses and the next one starts a new run, on
    /// the grounds that a person stopped and did something else.
    private static let pause: TimeInterval = 3

    static func runs(from presses: [ReceivedInput.Press]) -> [Run] {
        var runs: [Run] = []
        for press in presses {
            let printable = press.modifiers & ~0x02 == 0 && !press.characters.isEmpty
                && press.characters.rangeOfCharacter(from: .controlCharacters) == nil
            let breaks = press.usage == 40 || !printable
            let stale = runs.last.map { press.at.timeIntervalSince($0.began) > pause
                && !$0.text.isEmpty } ?? true

            if runs.isEmpty || stale || (breaks && !(runs.last?.text.isEmpty ?? true)) {
                runs.append(Run(began: press.at))
            }
            guard var current = runs.popLast() else { continue }
            current.count += 1
            if printable {
                current.text += press.characters
            } else {
                current.specials.append(press.label)
            }
            runs.append(current)
            // A newline closes the run it ends, so the next press starts fresh
            // rather than trailing after a line that is visibly finished.
            if press.usage == 40 { runs.append(Run(began: press.at)) }
        }
        return runs.filter { !$0.text.isEmpty || !$0.specials.isEmpty }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// A shade heavier than a terminal's usual weight. Thin monospace on a
    /// dark ground reads badly at a glance, which is how this is read.
    private func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("key log")
                    .font(mono(12, .semibold))
                    .foregroundStyle(Console.dim)
                Spacer(minLength: 8)
                Text(log.presses.isEmpty ? "waiting" : "\(log.total)")
                    .font(mono(12, .semibold))
                    .foregroundStyle(log.presses.isEmpty ? Console.dim : Console.text)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Rectangle().fill(Console.line).frame(height: 1)

            if log.presses.isEmpty {
                Text("Keys appear here as they arrive.\niOS gives them only to the app in front,\nso this stays empty while you use something else.")
                    .font(mono(12))
                    .foregroundStyle(Console.dim)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                let runs = Self.runs(from: log.presses).reversed()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(runs), id: \.id) { run in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.clock.string(from: run.began))
                                .font(mono(11, .regular))
                                .foregroundStyle(Console.dim)
                            if !run.text.isEmpty {
                                Text(run.text)
                                    .font(mono(14))
                                    .foregroundStyle(Console.text)
                                    .textSelection(.enabled)
                            }
                            if !run.specials.isEmpty {
                                Text(run.specials.joined(separator: " "))
                                    .font(mono(12, .semibold))
                                    .foregroundStyle(Console.special)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(Console.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Console.line, lineWidth: 1)
        )
    }
}
