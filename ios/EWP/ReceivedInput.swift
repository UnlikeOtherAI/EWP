import SwiftUI
import UIKit

/// What this device actually received from a hardware keyboard.
///
/// Everything else in EWP reports what was *sent*: `press_key` answers
/// `notified`, which means a HID report went out, and says plainly that it
/// does not mean the target acted on it. This is the other end of that. An
/// agent types, then reads back from the target exactly what arrived — the HID
/// usage, the modifier flags, the characters — so a keystroke can be checked
/// rather than assumed.
///
/// The limit is iOS's, and it is not small: an app only receives key presses
/// while it is frontmost and holds keyboard focus. Typing into Notes is
/// invisible here, and no background mode changes that — iOS does not deliver
/// key events to an app that is not in front, so a log cannot keep filling
/// while the device is used for something else. For debugging that is usually
/// what you want anyway, since you put EWP in front and type at it
/// deliberately. The screen is kept awake while the app runs, which is what
/// stops a device on a wall from suspending itself mid-session.
@MainActor
final class ReceivedInput: ObservableObject {
    struct Press: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        /// The HID usage, which is the same number `press_key` takes.
        let usage: Int
        /// The modifier bitmask in HID order, so it can be compared directly
        /// with what was sent rather than through Apple's own flag values.
        let modifiers: Int
        let characters: String
        let unmodified: String

        /// The eight bytes a HID keyboard would have put on the wire for this
        /// press. Reconstructed, not captured: iOS hands over a decoded key,
        /// not the report it came from, and the reserved byte and the five
        /// unused key slots are always zero here.
        var reportBytes: String {
            let bytes = [modifiers, 0, usage, 0, 0, 0, 0, 0]
            return bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        }

        var modifierNames: [String] {
            var names: [String] = []
            if modifiers & 0x01 != 0 { names.append("LeftCtrl") }
            if modifiers & 0x02 != 0 { names.append("LeftShift") }
            if modifiers & 0x04 != 0 { names.append("LeftAlt") }
            if modifiers & 0x08 != 0 { names.append("LeftGUI") }
            if modifiers & 0x10 != 0 { names.append("RightCtrl") }
            if modifiers & 0x20 != 0 { names.append("RightShift") }
            if modifiers & 0x40 != 0 { names.append("RightAlt") }
            if modifiers & 0x80 != 0 { names.append("RightGUI") }
            return names
        }

        /// What a person should see in a log: `Cmd+Shift+F3`, never `usage 60`.
        var label: String {
            let parts = modifierNames.map { name -> String in
                switch name {
                case "LeftCtrl", "RightCtrl": return "Ctrl"
                case "LeftShift", "RightShift": return "Shift"
                case "LeftAlt", "RightAlt": return "Alt"
                default: return "Cmd"
                }
            }
            return (Array(NSOrderedSet(array: parts)) as? [String] ?? []).joined(separator: "+")
                + (parts.isEmpty ? "" : "+") + HIDKeyName.of(usage)
        }
    }

    @Published private(set) var presses: [Press] = []
    /// Everything seen since launch, so a log that has rolled over still says
    /// how much it dropped.
    @Published private(set) var total = 0

    /// Kept for as long as the app runs, bounded so a device left recording
    /// overnight cannot grow until it is killed for memory. At 500 entries
    /// this is tens of kilobytes; `total` keeps counting past it so a log that
    /// has rolled over still says how much it dropped.
    private let limit = 500

    func record(usage: Int, modifiers: Int, characters: String, unmodified: String) {
        total += 1
        presses.append(Press(at: Date(), usage: usage, modifiers: modifiers,
                             characters: characters, unmodified: unmodified))
        if presses.count > limit { presses.removeFirst(presses.count - limit) }
    }

    func clear() { presses.removeAll(); total = 0 }

    /// Apple's flags are not the HID bitmask, so they are translated rather
    /// than passed through: an agent comparing what it sent with what arrived
    /// should be comparing like with like.
    static func hidModifiers(from flags: UIKeyModifierFlags) -> Int {
        var bits = 0
        if flags.contains(.control) { bits |= 0x01 }
        if flags.contains(.shift) { bits |= 0x02 }
        if flags.contains(.alternate) { bits |= 0x04 }
        if flags.contains(.command) { bits |= 0x08 }
        return bits
    }
}

/// Names for the usages a keyboard can send. `usage 73` is not a name, and a
/// log that prints numbers is no better than no log for the special keys this
/// is mostly used to debug.
enum HIDKeyName {
    static func of(_ usage: Int) -> String {
        switch usage {
        case 4...29: return String(UnicodeScalar(UInt8(usage - 4 + 97)))  // a to z
        case 30...38: return String(usage - 29)                            // 1 to 9
        case 39: return "0"
        case 40: return "Enter"
        case 41: return "Escape"
        case 42: return "Backspace"
        case 43: return "Tab"
        case 44: return "Space"
        case 45: return "Minus"
        case 46: return "Equals"
        case 47: return "LeftBracket"
        case 48: return "RightBracket"
        case 49: return "Backslash"
        case 51: return "Semicolon"
        case 52: return "Quote"
        case 53: return "Grave"
        case 54: return "Comma"
        case 55: return "Period"
        case 56: return "Slash"
        case 57: return "CapsLock"
        case 58...69: return "F\(usage - 57)"
        case 70: return "PrintScreen"
        case 71: return "ScrollLock"
        case 72: return "Pause"
        case 73: return "Insert"
        case 74: return "Home"
        case 75: return "PageUp"
        case 76: return "Delete"
        case 77: return "End"
        case 78: return "PageDown"
        case 79: return "Right"
        case 80: return "Left"
        case 81: return "Down"
        case 82: return "Up"
        case 83: return "NumLock"
        case 84...99: return "Keypad\(usage - 83)"
        case 100: return "NonUSBackslash"
        case 101: return "Application"
        case 104...115: return "F\(usage - 90)"
        case 224: return "LeftCtrl"
        case 225: return "LeftShift"
        case 226: return "LeftAlt"
        case 227: return "LeftGUI"
        case 228: return "RightCtrl"
        case 229: return "RightShift"
        case 230: return "RightAlt"
        case 231: return "RightGUI"
        default: return "usage \(usage)"
        }
    }
}

/// An invisible first responder. It exists only to receive hardware key
/// presses: `pressesBegan` is where `UIKey` arrives, and `UIKey.keyCode` is
/// the HID usage, which is why this can be compared with what was sent.
struct KeyCatcher: UIViewRepresentable {
    let log: ReceivedInput

    final class CatchingView: UIView {
        var log: ReceivedInput?
        override var canBecomeFirstResponder: Bool { true }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                guard let key = press.key else { continue }
                handled = true
                let usage = key.keyCode.rawValue
                log?.record(usage: usage,
                            modifiers: ReceivedInput.hidModifiers(from: key.modifierFlags),
                            characters: key.characters,
                            unmodified: key.charactersIgnoringModifiers)
            }
            // Anything not recognised goes on to the system, so this never
            // swallows a key it did not understand.
            if !handled { super.pressesBegan(presses, with: event) }
        }
    }

    func makeUIView(context: Context) -> CatchingView {
        let view = CatchingView()
        view.log = log
        view.backgroundColor = .clear
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: CatchingView, context: Context) {
        view.log = log
        if !view.isFirstResponder { view.becomeFirstResponder() }
    }
}
