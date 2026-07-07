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

    // U8 (CV-5): the tri-state cursor-style-blink (true / false / unset-null) is
    // presented toggle-first, so a raw "true" never renders in a picker. Its underlying
    // enumeration type is preserved so the unset state stays lossless.
    func testCursorStyleBlinkIsBooleanishTriState() throws {
        let catalog = try referenceCatalog()
        let blink = try XCTUnwrap(catalog.option(named: "cursor-style-blink"))
        XCTAssertTrue(blink.isBooleanish)
        XCTAssertEqual(blink.valueType, .enumeration)
        XCTAssertTrue(blink.enumValues.contains("true"))
        XCTAssertTrue(blink.enumValues.contains("false"))
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

    // MARK: - Effective/default value presentation (third-pass U2)

    func testUnsetCursorBlinkPresentsItsEffectiveOnDefault() throws {
        let option = try XCTUnwrap(referenceCatalog().option(named: "cursor-style-blink"))
        let merged = MergedOption(option: option, state: .unset, userValues: [], sources: [])

        XCTAssertEqual(merged.valuePresentation.value, "true")
        XCTAssertEqual(merged.valuePresentation.booleanValue, true)
        XCTAssertEqual(merged.valuePresentation.origin, .defaultValue)
    }

    func testUnsetPlainBooleansUseTheirDocumentedDefaults() throws {
        let catalog = try referenceCatalog()
        let trueOption = try XCTUnwrap(catalog.options.first {
            $0.valueType == .boolean && $0.defaultValue == "true"
        })
        let falseOption = try XCTUnwrap(catalog.options.first {
            $0.valueType == .boolean && $0.defaultValue == "false"
        })

        XCTAssertEqual(MergedOption(option: trueOption, state: .unset, userValues: [], sources: []).valuePresentation.booleanValue, true)
        XCTAssertEqual(MergedOption(option: falseOption, state: .unset, userValues: [], sources: []).valuePresentation.booleanValue, false)
    }

    func testUnknownEmptyDefaultRemainsUnresolved() {
        let option = CatalogOption(
            name: "future-option", defaultValues: [""], documentation: "",
            category: "Advanced", valueType: .unknown, enumValues: [], isRepeatable: false
        )
        let merged = MergedOption(option: option, state: .unset, userValues: [], sources: [])

        XCTAssertNil(merged.valuePresentation.value)
        XCTAssertEqual(merged.valuePresentation.origin, .unresolvedDefault)
    }

    func testExplicitValueEqualToDefaultStaysExplicit() throws {
        let option = try XCTUnwrap(referenceCatalog().options.first { !$0.defaultValue.isEmpty })
        let merged = MergedOption(
            option: option, state: .setToDefault,
            userValues: [option.defaultValue], sources: []
        )

        XCTAssertEqual(merged.valuePresentation.value, option.defaultValue)
        XCTAssertEqual(merged.valuePresentation.origin, .explicitValue)
        XCTAssertTrue(merged.valuePresentation.isExplicit)
    }

    func testUnresolvedBooleanishDefaultRequiresAThreeStateChoice() throws {
        let option = try XCTUnwrap(referenceCatalog().options.first {
            $0.isBooleanish && $0.defaultValue.isEmpty && $0.presentation.effectiveDefault == nil
        })
        let merged = MergedOption(option: option, state: .unset, userValues: [], sources: [])

        XCTAssertEqual(merged.booleanControlStyle, .defaultOnOffChoice)
    }

    func testKnownBooleanDefaultCanUseSwitch() throws {
        let option = try XCTUnwrap(referenceCatalog().option(named: "cursor-style-blink"))
        let merged = MergedOption(option: option, state: .unset, userValues: [], sources: [])

        XCTAssertEqual(merged.booleanControlStyle, .switch)
    }

    // MARK: - Enum value labels (CONTENT-8)

    func testEnumValueLabelReturnsFriendlyThenHumanizesUncuratedValues() {
        // U3 (CV-1/CM-1): an uncurated value is HUMANIZED, never rendered as its raw
        // token — a config token must never surface as a user-facing value.
        let labels = EnumValueLabels.bundled
        XCTAssertEqual(labels.label(option: "link-previews", value: "osc8"), "Only OSC 8 hyperlinks")
        XCTAssertEqual(labels.label(option: "link-previews", value: "weird"), "Weird")   // uncurated value → humanized
        XCTAssertEqual(labels.label(option: "no-such-option", value: "x"), "X")           // uncurated option → humanized
    }

    func testCatalogOptionEnumValueLabelConvenience() throws {
        let option = try referenceCatalog().option(named: "confirm-close-surface")!
        XCTAssertEqual(option.enumValueLabel("always"), "Always, even when idle")
        XCTAssertEqual(option.enumValueLabel("mystery"), "Mystery")   // uncurated → humanized, never raw (U3)
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
