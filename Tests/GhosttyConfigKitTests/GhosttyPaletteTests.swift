import XCTest
@testable import GhosttyConfigKit

/// B8 (U14): the pure palette value-list builder behind the swatch-grid editor (R5).
final class GhosttyPaletteTests: XCTestCase {

    func testParseReadsIndexColorPairs() {
        let slots = GhosttyPalette.parse(["0=#1d1f21", "8 = #585b70", "15=#ffffff"])
        XCTAssertEqual(slots[0], "#1d1f21")
        XCTAssertEqual(slots[8], "#585b70")   // whitespace around index/color trimmed
        XCTAssertEqual(slots[15], "#ffffff")
    }

    func testParseIgnoresMalformedAndOutOfRange() {
        let slots = GhosttyPalette.parse(["garbage", "x=#fff", "0=#1d1f21", "16=#000000", "3="])
        XCTAssertEqual(slots, [0: "#1d1f21"])   // no key, non-int, out-of-range, empty-color all dropped
    }

    func testParseKeepsLastForRepeatedIndex() {
        XCTAssertEqual(GhosttyPalette.parse(["4=#111111", "4=#222222"])[4], "#222222")
    }

    func testValueListIsSortedByIndex() {
        XCTAssertEqual(GhosttyPalette.valueList([8: "#585b70", 0: "#1d1f21", 4: "#abcdef"]),
                       ["0=#1d1f21", "4=#abcdef", "8=#585b70"])
    }

    func testSettingUpdatesOneSlotPreservingOthers() {
        let updated = GhosttyPalette.setting(index: 4, to: "#abcdef", in: ["0=#1d1f21", "4=#000000"])
        XCTAssertEqual(updated, ["0=#1d1f21", "4=#abcdef"])   // edited slot changes, others intact
    }

    func testSettingAppendsANewSlotInOrder() {
        let updated = GhosttyPalette.setting(index: 1, to: "#ff0000", in: ["0=#1d1f21", "8=#585b70"])
        XCTAssertEqual(updated, ["0=#1d1f21", "1=#ff0000", "8=#585b70"])
    }

    func testSettingEmptyClearsTheSlot() {
        let updated = GhosttyPalette.setting(index: 0, to: "  ", in: ["0=#1d1f21", "4=#abcdef"])
        XCTAssertEqual(updated, ["4=#abcdef"])   // cleared slot falls back to the theme
    }

    func testRoundTripThroughParseAndValueList() {
        let values = ["0=#1d1f21", "7=#c5c8c6", "15=#ffffff"]
        XCTAssertEqual(GhosttyPalette.valueList(GhosttyPalette.parse(values)), values)
    }
}
