import XCTest
@testable import GhosttyConfigKit

final class EnumChoicesTests: XCTestCase {

    private func enumOption(
        name: String = "cursor-style",
        values: [String] = ["block", "bar", "underline", "block_hollow"],
        default def: String = "block",
        state: OptionState,
        userValues: [String]
    ) -> MergedOption {
        let option = CatalogOption(
            name: name,
            defaultValues: [def],
            documentation: "",
            category: "Cursor",
            valueType: .enumeration,
            enumValues: values,
            isRepeatable: false
        )
        return MergedOption(option: option, state: state, userValues: userValues, sources: [])
    }

    // Current value is one of the listed choices → rows equal enumValues, no extra.
    func testCurrentValueInEnumSet() {
        let option = enumOption(state: .setNonDefault, userValues: ["bar"])
        let choices = option.enumChoices(current: "bar")
        XCTAssertEqual(choices.map(\.value), ["block", "bar", "underline", "block_hollow"])
        XCTAssertEqual(choices.filter(\.isSelected).map(\.value), ["bar"])
    }

    // AE3 (R3): a saved value outside the documented set is preserved, selected,
    // and leads the list; the documented order is otherwise intact.
    func testOutOfEnumCurrentValueIsPreservedAndSelected() {
        let option = enumOption(state: .setNonDefault, userValues: ["beam"])
        let choices = option.enumChoices(current: "beam")
        XCTAssertEqual(choices.map(\.value), ["beam", "block", "bar", "underline", "block_hollow"])
        XCTAssertEqual(choices.first?.value, "beam")
        XCTAssertTrue(choices.first?.isSelected == true)
        XCTAssertEqual(choices.first?.label, "beam — current value")
        XCTAssertEqual(choices.filter(\.isSelected).map(\.value), ["beam"])
    }

    // Unset, default IS a listed value → default selected, no spurious extra entry.
    func testUnsetWithListedDefault() {
        let option = enumOption(state: .unset, userValues: [])
        let choices = option.enumChoices(current: "block")
        XCTAssertEqual(choices.count, 4)
        XCTAssertEqual(choices.filter(\.isSelected).map(\.value), ["block"])
        XCTAssertEqual(choices.first?.label, "block") // not annotated
    }

    // Unset, empty/unlisted default (macos-option-as-alt) → distinct unset entry
    // whose tag matches the editor's seeded empty draft (avoids the blank-Picker
    // footgun, KTD4).
    func testUnsetWithEmptyDefaultGetsDistinctEntry() {
        let option = enumOption(
            name: "macos-option-as-alt",
            values: ["true", "false", "left", "right"],
            default: "",
            state: .unset,
            userValues: []
        )
        let choices = option.enumChoices(current: "")
        XCTAssertEqual(choices.count, 5)
        XCTAssertEqual(choices.first?.value, "")
        XCTAssertEqual(choices.first?.label, "Not set — uses default")
        XCTAssertTrue(choices.first?.isSelected == true)
        XCTAssertEqual(choices.filter(\.isSelected).count, 1)
    }

    // Unset, non-empty unlisted default → the unset entry shows the default.
    func testUnsetWithNonEmptyUnlistedDefaultShowsDefault() {
        let option = enumOption(
            name: "demo",
            values: ["a", "b"],
            default: "foo",
            state: .unset,
            userValues: []
        )
        let choices = option.enumChoices(current: "foo")
        XCTAssertEqual(choices.first?.value, "foo")
        XCTAssertEqual(choices.first?.label, "Not set — uses default (foo)")
    }

    // Current equals default and both are listed → no duplicate row.
    func testNoDuplicateWhenCurrentEqualsListedDefault() {
        let option = enumOption(state: .setToDefault, userValues: ["block"])
        let choices = option.enumChoices(current: "block")
        XCTAssertEqual(choices.count, 4)
        XCTAssertEqual(Set(choices.map(\.value)).count, 4)
        XCTAssertEqual(choices.filter(\.isSelected).map(\.value), ["block"])
    }
}
