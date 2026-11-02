import Foundation

/// The physical keyboard layout a board declares to its host, as the HID
/// country code from USB HID 1.11 section 6.2.1.
///
/// What it does: a host asks a keyboard, once, which layout its keys are in.
/// Answering 0 means "not supported", which is why macOS opens its Keyboard
/// Setup Assistant and asks a keyboard with no keys to press the one beside
/// its left Shift.
///
/// What it does not do: it does not decide what a key types. `press_key`
/// sends a HID usage, and the character that arrives is whatever that usage
/// means under the layout the host itself is set to. Typing arbitrary text
/// needs a character-to-usage map per layout, which nothing here has.
struct HIDKeyboardLayout: Identifiable, Equatable, Sendable {
    let code: UInt8
    /// The short name the board's `set_layout` tool accepts.
    let name: String
    let label: String

    var id: UInt8 { code }

    /// Offered when the region says nothing useful. International (ISO) is
    /// the safest answer for a board with no opinion, and any answer beats 0.
    static let international = HIDKeyboardLayout(code: 13, name: "iso", label: "International (ISO)")

    static let all: [HIDKeyboardLayout] = [
        international,
        HIDKeyboardLayout(code: 33, name: "us", label: "United States"),
        HIDKeyboardLayout(code: 32, name: "uk", label: "United Kingdom"),
        HIDKeyboardLayout(code: 5, name: "cz", label: "Czech"),
        HIDKeyboardLayout(code: 24, name: "sk", label: "Slovak"),
        HIDKeyboardLayout(code: 9, name: "de", label: "German"),
        HIDKeyboardLayout(code: 8, name: "fr", label: "French"),
        HIDKeyboardLayout(code: 2, name: "be", label: "Belgian"),
        HIDKeyboardLayout(code: 14, name: "it", label: "Italian"),
        HIDKeyboardLayout(code: 25, name: "es", label: "Spanish"),
        HIDKeyboardLayout(code: 18, name: "nl", label: "Dutch"),
        HIDKeyboardLayout(code: 21, name: "pl", label: "Polish"),
        HIDKeyboardLayout(code: 22, name: "pt", label: "Portuguese"),
        HIDKeyboardLayout(code: 26, name: "se", label: "Swedish"),
        HIDKeyboardLayout(code: 19, name: "no", label: "Norwegian"),
        HIDKeyboardLayout(code: 6, name: "dk", label: "Danish"),
        HIDKeyboardLayout(code: 7, name: "fi", label: "Finnish"),
        HIDKeyboardLayout(code: 12, name: "hu", label: "Hungarian"),
        HIDKeyboardLayout(code: 10, name: "gr", label: "Greek"),
        HIDKeyboardLayout(code: 11, name: "il", label: "Hebrew"),
        HIDKeyboardLayout(code: 23, name: "ru", label: "Russian"),
        HIDKeyboardLayout(code: 31, name: "tr", label: "Turkish"),
        HIDKeyboardLayout(code: 29, name: "ch", label: "Swiss"),
        HIDKeyboardLayout(code: 3, name: "ca", label: "Canadian"),
        HIDKeyboardLayout(code: 17, name: "latam", label: "Latin American"),
        HIDKeyboardLayout(code: 15, name: "jp", label: "Japanese"),
        HIDKeyboardLayout(code: 16, name: "kr", label: "Korean"),
        HIDKeyboardLayout(code: 30, name: "tw", label: "Taiwanese"),
    ]

    /// Regions whose keyboards are not the layout their language suggests are
    /// here on purpose: Austria uses the German layout, Ireland the British
    /// one, and Australia, New Zealand and India the US one. A region with no
    /// entry is not guessed at.
    private static let byRegion: [String: UInt8] = [
        "CZ": 5, "SK": 24,
        "DE": 9, "AT": 9,
        "FR": 8, "BE": 2, "CH": 29,
        "IT": 14, "ES": 25, "NL": 18, "PL": 21, "PT": 22,
        "SE": 26, "NO": 19, "DK": 6, "FI": 7,
        "HU": 12, "GR": 10, "IL": 11, "RU": 23, "TR": 31,
        "GB": 32, "IE": 32,
        "US": 33, "AU": 33, "NZ": 33, "IN": 33,
        "CA": 3,
        "MX": 17, "AR": 17, "CL": 17, "CO": 17, "PE": 17,
        "JP": 15, "KR": 16, "TW": 30,
    ]

    /// The layout to offer first for a region identifier such as `CZ`.
    /// Anything unrecognised, including nil and the empty string, falls back
    /// to International rather than guessing.
    static func forRegion(_ region: String?) -> HIDKeyboardLayout {
        guard let region, !region.isEmpty,
              let code = byRegion[region.uppercased()],
              let match = all.first(where: { $0.code == code })
        else { return international }
        return match
    }

    /// The layout to offer first on this device.
    static var fromCurrentLocale: HIDKeyboardLayout {
        forRegion(Locale.current.region?.identifier)
    }

    static func named(_ code: UInt8) -> HIDKeyboardLayout? {
        all.first { $0.code == code }
    }
}
