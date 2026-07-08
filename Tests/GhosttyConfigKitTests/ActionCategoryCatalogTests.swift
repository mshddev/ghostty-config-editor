import XCTest
@testable import GhosttyConfigKit

final class ActionCategoryCatalogTests: XCTestCase {

    private func actionNames() throws -> Set<String> {
        Set(KeybindReference.parseActions(try Fixture.text("list-actions", "txt")).map(\.name))
    }

    private func group(_ action: String) -> KeybindActionGroup {
        KeybindActionGroup(action: action, chords: [
            MergedKeybind(trigger: "", action: action, canonicalTrigger: "", origin: .unbound, source: nil)
        ])
    }

    // MARK: - Orphan guard (KTD1)

    func testEveryCategorizedActionResolvesInFixture() throws {
        let actions = try actionNames()
        let orphans = ActionCategoryCatalog.bundled.categorizedActionNames.subtracting(actions)
        XCTAssertTrue(orphans.isEmpty,
                      "action-categories.json has keys absent from +list-actions: \(orphans.sorted())")
    }

    // MARK: - Fallback + param stripping

    func testUncategorizedActionFallsIntoOther() {
        XCTAssertEqual(ActionCategoryCatalog.bundled.sectionID(forAction: "some_future_action"),
                       ActionCategoryCatalog.otherSection.id)
    }

    func testShippedCatalogHasNoDanglingSectionReferences() {
        // Referential integrity: every action's `section` must be a declared section id.
        let dangling = ActionCategoryCatalog.bundled.danglingSectionActions
        XCTAssertTrue(dangling.isEmpty,
                      "action-categories.json maps actions to undeclared sections: \(dangling.sorted())")
    }

    func testAnUndeclaredSectionDegradesToOtherRatherThanVanishing() {
        // A typo'd section id must not make the action disappear — it lands in Other.
        let catalog = ActionCategoryCatalog(
            sections: [ActionSection(id: "splits", title: "Splits")],
            categories: ["new_split": ActionCategory(section: "splits", rank: 1),
                         "goto_split": ActionCategory(section: "splts", rank: 2)])  // deliberate typo
        XCTAssertEqual(catalog.sectionID(forAction: "goto_split"), ActionCategoryCatalog.otherSection.id)
        XCTAssertEqual(catalog.danglingSectionActions, ["goto_split"])
        let sections = catalog.sections(for: [group("new_split"), group("goto_split")])
        XCTAssertEqual(sections.map(\.id), ["splits", ActionCategoryCatalog.otherSection.id])
        XCTAssertEqual(sections.last?.groups.map(\.action), ["goto_split"], "the typo'd action isn't dropped")
    }

    func testParamIsStrippedWhenResolvingSection() {
        // goto_tab:1…8 all resolve to the same (goto_tab) section.
        XCTAssertEqual(ActionCategoryCatalog.bundled.sectionID(forAction: "goto_tab:3"), "windows_tabs")
        XCTAssertEqual(ActionCategoryCatalog.bundled.sectionID(forAction: "goto_tab:3"),
                       ActionCategoryCatalog.bundled.sectionID(forAction: "goto_tab"))
    }

    // MARK: - Ordering

    func testSectionsAreOrderedWithOtherLastAndRankedWithin() throws {
        // Deliberately out of order, with one uncategorized action.
        let groups = [group("new_tab"), group("goto_split"), group("new_window"),
                      group("zzz_uncategorized"), group("close_window")]
        let sections = ActionCategoryCatalog.bundled.sections(for: groups)

        XCTAssertEqual(sections.first?.id, "windows_tabs", "curated sections come first, in catalog order")
        XCTAssertEqual(sections.last?.id, ActionCategoryCatalog.otherSection.id, "Other is always last")
        XCTAssertEqual(sections.last?.groups.map(\.action), ["zzz_uncategorized"])

        // Within Windows & Tabs, groups sort by curated rank: new_window(1) < close_window(2) < new_tab(4).
        let windows = try XCTUnwrap(sections.first)
        XCTAssertEqual(windows.groups.map(\.action), ["new_window", "close_window", "new_tab"])

        // Splits appears between Windows & Tabs and Other.
        XCTAssertEqual(sections.map(\.id), ["windows_tabs", "splits", ActionCategoryCatalog.otherSection.id])
    }

    func testEmptySectionsAreOmitted() {
        let sections = ActionCategoryCatalog.bundled.sections(for: [group("copy_to_clipboard")])
        XCTAssertEqual(sections.map(\.id), ["editing_clipboard"], "only the section with a row shows")
    }

    // MARK: - Section filter (D)

    func testGroupsInSectionKeepsOnlyThatSectionPreservingOrderAndStrippingParams() {
        let catalog = ActionCategoryCatalog.bundled
        // new_window + goto_tab:3 → Windows & Tabs; new_split → Splits; search → Search.
        let input = [group("new_window"), group("new_split"), group("search"), group("goto_tab:3")]

        XCTAssertEqual(catalog.groups(input, inSection: "windows_tabs").map(\.action),
                       ["new_window", "goto_tab:3"],
                       "keeps only Windows & Tabs actions, in input order, with params stripped for matching")
        XCTAssertEqual(catalog.groups(input, inSection: "splits").map(\.action), ["new_split"])
        XCTAssertTrue(catalog.groups(input, inSection: "font").isEmpty,
                      "a section with no matching input yields an empty list")
    }

    // MARK: - Coverage

    func testEveryDefaultBoundActionLandsInACuratedSection() throws {
        // KB-9/KB-10: the actions that ship a default keybind should read under a heading,
        // not spill into Other.
        let names = try actionNames()
        let defaults = KeybindReference.parseDefaults(try Fixture.text("list-keybinds-default", "txt"),
                                                      knownActions: names)
        let catalog = ActionCategoryCatalog.bundled
        let inOther = Set(defaults.map { Keybind.actionName($0.action) })
            .filter { catalog.sectionID(forAction: $0) == ActionCategoryCatalog.otherSection.id }
        XCTAssertTrue(inOther.isEmpty, "default-bound actions fell into Other: \(inOther.sorted())")
    }
}
