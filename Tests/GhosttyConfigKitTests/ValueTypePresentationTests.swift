import XCTest
@testable import GhosttyConfigKit

final class ValueTypePresentationTests: XCTestCase {

    // MARK: - Value-type display names (CONTENT-7)

    func testValueTypeDisplayNamesMapEachCase() {
        XCTAssertEqual(OptionValueType.boolean.displayName, "On/off")
        XCTAssertEqual(OptionValueType.number.displayName, "Number")
        XCTAssertEqual(OptionValueType.color.displayName, "Color")
        XCTAssertEqual(OptionValueType.enumeration.displayName, "Choice")
        XCTAssertEqual(OptionValueType.string.displayName, "Text")
    }

    func testUnknownValueTypeHasNoDisplayName() {
        XCTAssertNil(OptionValueType.unknown.displayName)
    }

    // MARK: - Boolean-ish presentation hint (CONTROLS-2, U10)

    func testImpostorAndOpenValuedOptionsAreBooleanish() throws {
        let catalog = try referenceCatalog()
        XCTAssertTrue(catalog.option(named: "background-blur")!.isBooleanish)
        XCTAssertTrue(catalog.option(named: "confirm-close-surface")!.isBooleanish)
    }

    func testBooleanishPreservesRawValueType() throws {
        let catalog = try referenceCatalog()
        // The hint must not coerce the type: background-blur stays open-valued text,
        // confirm-close-surface stays an enumeration (so extra states aren't lost).
        XCTAssertEqual(catalog.option(named: "background-blur")!.valueType, .string)
        XCTAssertEqual(catalog.option(named: "confirm-close-surface")!.valueType, .enumeration)
    }

    func testPlainBooleansAreNeverBooleanish() throws {
        // Invariant: a real `.boolean` already drives a toggle, so it must not carry
        // the impostor/open-valued hint. Robust to the fixture's parsed defaults.
        for option in try referenceCatalog().options where option.valueType == .boolean {
            XCTAssertFalse(option.isBooleanish, "\(option.name) is a plain boolean, not booleanish")
        }
    }

    // MARK: - Enum value labels (CONTENT-8)

    func testEnumValueLabelReturnsFriendlyThenFallsBackToRaw() {
        let labels = EnumValueLabels.bundled
        XCTAssertEqual(labels.label(option: "link-previews", value: "osc8"), "Only OSC 8 hyperlinks")
        XCTAssertEqual(labels.label(option: "link-previews", value: "weird"), "weird")   // uncurated value → raw
        XCTAssertEqual(labels.label(option: "no-such-option", value: "x"), "x")           // uncurated option → raw
    }

    func testCatalogOptionEnumValueLabelConvenience() throws {
        let option = try referenceCatalog().option(named: "confirm-close-surface")!
        XCTAssertEqual(option.enumValueLabel("always"), "Always, even when idle")
        XCTAssertEqual(option.enumValueLabel("mystery"), "mystery")
    }

    func testEnumValueLabelOptionKeysResolveInCatalog() throws {
        let names = Set(try referenceCatalog().options.map(\.name))
        let orphans = EnumValueLabels.bundled.labeledOptionNames.subtracting(names)
        XCTAssertTrue(orphans.isEmpty, "enum-value-labels.json has option keys absent from the catalog: \(orphans.sorted())")
    }

    private func referenceCatalog() throws -> OptionCatalog {
        CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"))
    }
}
