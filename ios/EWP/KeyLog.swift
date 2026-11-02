import SwiftUI

/// What came through the keyboard, as a person reads it rather than as a
/// machine does. `received_input` serves the same presses over MCP with every
/// field intact; this is the view for whoever is holding the device.
///
/// Presses are gathered into runs rather than listed one per line. A line of
/// typing is one event to a person, not forty, and timestamping every letter
/// buries the thing you are looking for. A run ends at a newline, at a key
/// that is not a character, or after a pause, and carries the time it began.
struct KeyLogView: View {
    @ObservedObject var log: ReceivedInput

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

    var body: some View {
        Card {
            CardRow(divider: !log.presses.isEmpty) {
                BlockLabel(title: "Key log") {
                    Beacon(text: log.presses.isEmpty ? "WAITING" : "\(log.total)",
                           tint: log.presses.isEmpty ? Theme.subtle : Theme.accent,
                           breathing: !log.presses.isEmpty)
                }
            }
            if log.presses.isEmpty {
                CardRow(divider: false) {
                    Text("Keys appear here as they arrive. iOS gives them only to the app in front, so this stays empty while you use something else.")
                        .font(.footnote)
                        .foregroundStyle(Theme.subtle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                let runs = Self.runs(from: log.presses).reversed()
                ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                    CardRow(divider: index < runs.count - 1) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Self.clock.string(from: run.began))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.subtle)
                                Spacer(minLength: 0)
                                Text("\(run.count)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.subtle.opacity(0.7))
                            }
                            if !run.text.isEmpty {
                                Text(run.text)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundStyle(Theme.ink)
                                    .textSelection(.enabled)
                            }
                            if !run.specials.isEmpty {
                                Text(run.specials.joined(separator: "  "))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
