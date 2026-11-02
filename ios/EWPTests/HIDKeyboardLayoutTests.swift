import XCTest
@testable import EWP

/// The region map is the only part of the layout feature that guesses, so it
/// is the part worth pinning down.
final class HIDKeyboardLayoutTests: XCTestCase {
    func testKnownRegionsMapToTheirLayout() {
        XCTAssertEqual(HIDKeyboardLayout.forRegion("CZ").code, 5)
        XCTAssertEqual(HIDKeyboardLayout.forRegion("GB").code, 32)
        XCTAssertEqual(HIDKeyboardLayout.forRegion("US").code, 33)
        XCTAssertEqual(HIDKeyboardLayout.forRegion("JP").code, 15)
    }

    func testRegionsThatDoNotMatchTheirLanguage() {
        // Austria types on a German layout, Ireland on a British one, and
        // Australia, New Zealand and India on a US one.
        XCTAssertEqual(HIDKeyboardLayout.forRegion("AT").code, 9)
        XCTAssertEqual(HIDKeyboardLayout.forRegion("IE").code, 32)
        XCTAssertEqual(HIDKeyboardLayout.forRegion("AU").code, 33)
        XCTAssertEqual(HIDKeyboardLayout.forRegion("NZ").code, 33)
        XCTAssertEqual(HIDKeyboardLayout.forRegion("IN").code, 33)
    }

    func testLowercaseAndMixedCaseRegionsStillMatch() {
        XCTAssertEqual(HIDKeyboardLayout.forRegion("cz").code, 5)
        XCTAssertEqual(HIDKeyboardLayout.forRegion("Gb").code, 32)
    }

    func testUnknownRegionsFallBackToInternational() {
        // Never a guess: an unmapped region gets ISO, which is the safe
        // answer, rather than whatever its neighbour uses.
        for region in ["ZZ", "BR", "ZA", "", "  "] {
            XCTAssertEqual(HIDKeyboardLayout.forRegion(region).code, 13,
                           "expected International for \(region.isEmpty ? "empty" : region)")
        }
        XCTAssertEqual(HIDKeyboardLayout.forRegion(nil).code, 13)
    }

    func testInternationalIsNeverZero() {
        // 0 is "not supported", which is the state this whole feature exists
        // to get the board out of.
        XCTAssertEqual(HIDKeyboardLayout.international.code, 13)
        XCTAssertFalse(HIDKeyboardLayout.all.contains { $0.code == 0 })
    }

    func testEveryOfferedLayoutIsDistinctAndNameable() {
        let codes = HIDKeyboardLayout.all.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "duplicate HID country codes offered")
        let names = HIDKeyboardLayout.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate layout names offered")
        for layout in HIDKeyboardLayout.all {
            XCTAssertFalse(layout.label.isEmpty)
            XCTAssertEqual(HIDKeyboardLayout.named(layout.code), layout)
        }
    }

    func testEveryRegionMapsToALayoutThatIsOffered() {
        // A region pointing at a code the picker does not list would silently
        // fall back to International, which would look like a missing map.
        for region in ["CZ", "SK", "DE", "AT", "FR", "BE", "CH", "IT", "ES", "NL",
                       "PL", "PT", "SE", "NO", "DK", "FI", "HU", "GR", "IL", "RU",
                       "TR", "GB", "IE", "US", "AU", "NZ", "IN", "CA", "MX", "AR",
                       "CL", "CO", "PE", "JP", "KR", "TW"] {
            let layout = HIDKeyboardLayout.forRegion(region)
            XCTAssertNotEqual(layout.code, 13, "\(region) fell back instead of mapping")
        }
    }
}
