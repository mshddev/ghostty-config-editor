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
        XCTAssertEqual(choices.first?.label, "Block") // curated (U3), not annotated with " — …"
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

    // B4: friendly enum labels — row text is the curated label while the tag stays
    // the raw token Ghostty expects.
    func testFriendlyEnumLabelsWithRawTags() {
        let option = enumOption(
            name: "macos-option-as-alt",
            values: ["true", "false", "left", "right"],
            default: "true",
            state: .setNonDefault,
            userValues: ["left"]
        )
        let choices = option.enumChoices(current: "left")
        XCTAssertEqual(choices.map(\.value), ["true", "false", "left", "right"], "tags stay raw")
        XCTAssertEqual(choices.map(\.label),
                       ["Both Option keys", "Off", "Left Option only", "Right Option only"],
                       "labels are the curated friendly strings")
        XCTAssertEqual(choices.filter(\.isSelected).map(\.value), ["left"])
    }

    // U3 (CV-1): an option with no curated value labels HUMANIZES its labels — a raw
    // config token never surfaces as a choice — while the tags stay the raw values.
    func testUncuratedEnumHumanizesLabelsButKeepsRawTags() {
        let option = enumOption(
            name: "demo-uncurated",
            values: ["alpha_one", "beta"],
            default: "alpha_one",
            state: .setNonDefault,
            userValues: ["beta"]
        )
        let choices = option.enumChoices(current: "beta")
        XCTAssertEqual(choices.map(\.value), ["alpha_one", "beta"], "tags stay raw for Ghostty")
        XCTAssertEqual(choices.map(\.label), ["Alpha one", "Beta"], "labels humanized, never the raw token")
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
