import XCTest
@testable import GhosttyConfigEditor
@testable import GhosttyConfigKit

/// Pure navigation + search-scope policy (U5, R9/R10, F3/F4, AE7). Exercises the
/// `AppModel` transitions and the Problems action routing directly — no SwiftUI
/// rendering, no live `NSApplication` — so the wayfinding decisions are unit-testable
/// (KTD7). Marked `@MainActor` because `AppModel` is `@MainActor @Observable`.
@MainActor
final class NavigationPolicyTests: XCTestCase {

    // MARK: - Status destination (KTD6, AE7 scenario 3)

    // AE7: on the Customized drill-down (selection stays `.status`), reselecting the
    // Status footer returns to the hub rather than staying on Customized.
    func testReselectingStatusFromCustomizedReturnsToHub() {
        let model = AppModel()
        model.setStatusDestination(.customized)
        XCTAssertEqual(model.selection, .status)
        XCTAssertEqual(model.statusDestination, .customized)

        // Reselecting the Status footer re-assigns `.status` (the drill-down kept it).
        model.selection = .status
        XCTAssertEqual(model.statusDestination, .hub, "reselecting Status must return to the hub")
    }

    // AE7: the same holds for the Problems drill-down.
    func testReselectingStatusFromProblemsReturnsToHub() {
        let model = AppModel()
        model.setStatusDestination(.problems)
        XCTAssertEqual(model.selection, .status)
        XCTAssertEqual(model.statusDestination, .problems)

        model.selection = .status
        XCTAssertEqual(model.statusDestination, .hub)
    }

    // AE7: the breadcrumb / Back to Status link returns to the hub while keeping the
    // sidebar on `.status`.
    func testBackLinkReturnsToHub() {
        let model = AppModel()
        model.setStatusDestination(.problems)
        model.setStatusDestination(.hub)   // "Back to Status"
        XCTAssertEqual(model.selection, .status)
        XCTAssertEqual(model.statusDestination, .hub)
    }

    // A drill-down destination is inert once the user navigates to a real category, and a
    // later return to Status still lands on the hub (never a stale sub-surface).
    func testNavigatingAwayThenBackToStatusLandsOnHub() {
        let model = AppModel()
        model.setStatusDestination(.customized)
        model.selection = .category("Appearance")
        XCTAssertEqual(model.selection, .category("Appearance"))

        model.selection = .status
        XCTAssertEqual(model.statusDestination, .hub)
    }

    // The Customized/Problems drill-downs are represented purely by the destination —
    // `selection` is never one of them (they were removed as selection cases, KTD6).
    func testDrillDownSurfaceFlags() {
        let model = AppModel()
        XCTAssertFalse(model.isShowingCustomized)
        XCTAssertFalse(model.isShowingProblems)

        model.setStatusDestination(.customized)
        XCTAssertTrue(model.isShowingCustomized)
        XCTAssertFalse(model.isShowingProblems)

        model.setStatusDestination(.problems)
        XCTAssertFalse(model.isShowingCustomized)
        XCTAssertTrue(model.isShowingProblems)
    }

    // MARK: - Global Find result focus (F3 scenario 2)

    // Scenario 2: selecting a global Find result clears the local + global queries,
    // selects the option's category, and requests the focus scroll.
    func testFocusFromGlobalResultClearsQueriesSelectsCategoryAndRequestsFocus() {
        let model = AppModel()
        model.beginFind()
        model.findQuery = "opacity"
        model.query = "left over local filter"
        let before = model.focusRequestID

        model.focus(optionNamed: "background-opacity")

        XCTAssertEqual(model.query, "", "local filter must clear")
        XCTAssertEqual(model.findQuery, "", "global Find query must clear")
        XCTAssertFalse(model.isFinding, "global Find overlay must close")
        XCTAssertEqual(model.selection, .category(OptionCategorizer.category(for: "background-opacity")))
        XCTAssertEqual(model.selectedOptionName, "background-opacity")
        XCTAssertTrue(model.pendingFocusScroll, "the option row must be armed to scroll into view")
        XCTAssertEqual(model.focusRequestID, before + 1)
    }

    // A keybind focus target routes to Keyboard Shortcuts (its dedicated surface) without
    // arming the option-list scroll — that surface has no option rows.
    func testFocusOnKeybindRoutesToShortcutsWithoutArmingScroll() {
        let model = AppModel()
        model.focus(optionNamed: "keybind")
        XCTAssertEqual(model.selection, .category(OptionCategorizer.keybindingsCategory))
        XCTAssertFalse(model.pendingFocusScroll)
    }

    // `theme` has a dedicated Themes browser, so a focus routes there rather than to a
    // category option list that filters `theme` out.
    func testFocusOnThemeRoutesToThemesBrowser() {
        let model = AppModel()
        model.focus(optionNamed: "theme")
        XCTAssertEqual(model.selection, .themes)
        XCTAssertNil(model.selectedOptionName)
    }

    // MARK: - Local search scope naming + clearing (F3 scenario 1 + 5)

    // Scenario 5: clearing the local search restores the prior category surface (title +
    // split-section disclosure) without losing the sidebar selection.
    func testClearingLocalSearchRestoresCategorySurface() {
        let model = AppModel()
        model.selection = .category("Appearance")
        XCTAssertTrue(model.showsSplitSections)

        model.query = "cursor"
        XCTAssertFalse(model.showsSplitSections, "an active local search is a flat ranked list, not split sections")

        model.query = ""
        XCTAssertEqual(model.selection, .category("Appearance"), "clearing search must keep the sidebar selection")
        XCTAssertTrue(model.showsSplitSections, "the category's Common/Advanced sections return")
        XCTAssertEqual(model.currentSurfaceName, "Appearance")
    }

    // R9/F3: the local search field names its scope ("Search Appearance") so a local
    // filter is visibly scoped to the current category.
    func testLocalSearchPromptNamesCategoryScope() {
        let model = AppModel()
        model.selection = .category("Appearance")
        XCTAssertEqual(model.localSearchScopeCategory, "Appearance")
        XCTAssertEqual(model.localSearchPrompt, "Search Appearance")
    }

    // The current surface name follows the Customized drill-down too, so its header/scope
    // reads "Customized" rather than "Status".
    func testCurrentSurfaceNameFollowsCustomizedDrillDown() {
        let model = AppModel()
        model.setStatusDestination(.customized)
        XCTAssertEqual(model.currentSurfaceName, "Customized")
    }

    // MARK: - Section-search clearing on navigation (B2)

    // Moving to a different sidebar section clears that section's own search field
    // (`query`/`themeQuery`) so each surface opens fresh — but leaves the global Find
    // query untouched (navigation keeps clearing the *overlay* in the view layer, not the
    // model-level query the user chose to preserve here).
    func testSwitchingSidebarSectionClearsSectionSearchNotGlobalQuery() {
        let model = AppModel()
        model.selection = .category("Appearance")
        model.query = "font"
        model.themeQuery = "dracula"
        model.findQuery = "opacity"          // a global search the user had run

        model.selection = .category("Window")   // move to another section

        XCTAssertEqual(model.query, "", "the section search must clear on navigation")
        XCTAssertEqual(model.themeQuery, "", "the themes search must clear on navigation")
        XCTAssertEqual(model.findQuery, "opacity",
                       "changing the section must not touch the global Find query")
    }

    // The clear is guarded to a *real* section change: re-selecting the current section
    // (e.g. clicking the already-selected sidebar row, or a redundant layout re-assignment)
    // must not wipe an in-progress search.
    func testReselectingTheSameSectionKeepsItsSearch() {
        let model = AppModel()
        model.selection = .category("Appearance")
        model.query = "font"

        model.selection = .category("Appearance")   // same value re-assigned

        XCTAssertEqual(model.query, "font",
                       "re-selecting the current section must not wipe an in-progress search")
    }

    // MARK: - Problems row actions (F4/R10 scenario 4)

    // Scenario 4: a validation message whose key names a real catalog option offers
    // "Show Setting" (focus), independent of a live browser.
    func testValidationMessageWithKnownKeyOffersShowSetting() throws {
        let known = try referenceCatalogOptionNames()
        let message = ValidationMessage(file: "/tmp/config", line: 3, key: "font-size", message: "invalid")
        XCTAssertEqual(
            ProblemActionPolicy.action(for: message, fallbackPath: "/tmp/config") { known.contains($0) },
            .showSetting(optionName: "font-size")
        )
    }

    // Scenario 4: a validation line with a file + line but no mapped key offers an
    // Open-at-Line file action rather than a dead Show Setting.
    func testKeylessValidationLineOffersFileAction() throws {
        let known = try referenceCatalogOptionNames()
        let message = ValidationMessage(file: "/tmp/config", line: 7, key: nil, message: "syntax error")
        XCTAssertEqual(
            ProblemActionPolicy.action(for: message, fallbackPath: "/tmp/config") { known.contains($0) },
            .openFile(path: "/tmp/config", line: 7)
        )
    }

    // A validation line naming a key the catalog doesn't carry falls back to the file
    // action too (an unmapped key is not a focusable setting).
    func testUnknownKeyFallsBackToFileAction() throws {
        let known = try referenceCatalogOptionNames()
        let message = ValidationMessage(file: "/tmp/config", line: 9, key: "not-a-real-option", message: "boom")
        XCTAssertEqual(
            ProblemActionPolicy.action(for: message, fallbackPath: "/tmp/config") { known.contains($0) },
            .openFile(path: "/tmp/config", line: 9)
        )
    }

    // Scenario 4: a static footgun finding is a file-only warning — it offers a file
    // action at its first location, never a Show Setting.
    func testFootgunFindingOffersFileAction() {
        let finding = LintFinding(
            rule: "keybind-clears-all", severity: .warning, title: "t", message: "m",
            locations: [SettingLocation(file: "/tmp/config", line: 2)]
        )
        XCTAssertEqual(ProblemActionPolicy.action(for: finding), .openFile(path: "/tmp/config", line: 2))
    }

    /// Option names from the reference catalog fixture (shared with the kit test target
    /// via `#filePath`, mirroring `PresentationPolicyTests`).
    private func referenceCatalogOptionNames() throws -> Set<String> {
        let fixture = URL(fileURLWithPath: #filePath)          // …/Tests/GhosttyConfigEditorTests/NavigationPolicyTests.swift
            .deletingLastPathComponent()                        // GhosttyConfigEditorTests
            .deletingLastPathComponent()                        // Tests
            .appendingPathComponent("GhosttyConfigKitTests/Fixtures/show-config-default-docs.txt")
        let catalog = CatalogParser.parse(try String(contentsOf: fixture, encoding: .utf8))
        return Set(catalog.options.map(\.name))
    }
}
