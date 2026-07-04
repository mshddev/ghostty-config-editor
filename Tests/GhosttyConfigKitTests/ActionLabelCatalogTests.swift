import XCTest
@testable import GhosttyConfigKit

final class ActionLabelCatalogTests: XCTestCase {

    func testCuratedTitleForAction() {
        XCTAssertEqual(ActionLabelCatalog.bundled.displayTitle(forAction: "copy_to_clipboard"), "Copy")
        XCTAssertEqual(ActionLabelCatalog.bundled.displayTitle(forAction: "goto_split"), "Focus a split")
    }

    func testHumanizerFallbackForUncuratedAction() {
        XCTAssertEqual(ActionLabelCatalog.humanizeActionName("scroll_page_fractional"), "Scroll page fractional")
        XCTAssertEqual(ActionLabelCatalog.bundled.displayTitle(forAction: "scroll_page_fractional"), "Scroll page fractional")
    }

    func testParamHumanizedSeparatelyFromBaseTitle() {
        XCTAssertEqual(ActionLabelCatalog.humanizeParam(":previous"), "(previous)")
        XCTAssertEqual(ActionLabelCatalog.humanizeParam(":mixed"), "(mixed)")
        XCTAssertEqual(ActionLabelCatalog.humanizeParam("top_left"), "(top left)")
        // Full action combines base title + parenthetical param.
        XCTAssertEqual(ActionLabelCatalog.bundled.displayTitle(for: "goto_split:previous"), "Focus a split (previous)")
    }

    func testUnknownActionStillYieldsReadableTitle() {
        let title = ActionLabelCatalog.bundled.displayTitle(forAction: "some_new_action")
        XCTAssertFalse(title.isEmpty)
        XCTAssertEqual(title, "Some new action")
    }

    func testActionParamExtraction() {
        XCTAssertEqual(ActionLabelCatalog.actionParam("goto_split:previous"), "previous")
        XCTAssertNil(ActionLabelCatalog.actionParam("copy_to_clipboard"))
    }

    func testEveryFixtureActionYieldsNonEmptyTitle() throws {
        let actions = KeybindReference.parseActions(try Fixture.text("list-actions", "txt"))
        XCTAssertFalse(actions.isEmpty)
        for action in actions {
            XCTAssertFalse(action.displayTitle.isEmpty, "empty title for \(action.name)")
        }
    }

    func testEveryCuratedActionKeyResolvesInFixture() throws {
        // KTD1: a curated key that no longer exists in +list-actions must fail.
        let actions = Set(KeybindReference.parseActions(try Fixture.text("list-actions", "txt")).map(\.name))
        let orphans = ActionLabelCatalog.bundled.curatedActionNames.subtracting(actions)
        XCTAssertTrue(orphans.isEmpty, "action-labels.json has keys absent from +list-actions: \(orphans.sorted())")
    }

    func testKeybindActionDisplayTitleConvenience() {
        XCTAssertEqual(KeybindAction(name: "copy_to_clipboard").displayTitle, "Copy")
    }

    // MARK: - Param-fold decision (KB-4, U18)

    func testMultiParamActionsCountsOnlyBasesWithMoreThanOneDistinctParam() {
        let actions = ["goto_tab:1", "goto_tab:2", "goto_tab:3",
                       "copy_to_clipboard:mixed", "copy_to_clipboard:mixed",  // one distinct param
                       "reload_config"]                                        // no param
        let fold = ActionLabelCatalog.multiParamActions(in: actions)
        XCTAssertTrue(fold.contains("goto_tab"), "3 distinct params → fold")
        XCTAssertFalse(fold.contains("copy_to_clipboard"), "one distinct param (mixed) → don't fold")
        XCTAssertFalse(fold.contains("reload_config"), "no param → don't fold")
    }

    func testDisplayTitleFoldsParamOnlyForMultiParamBases() {
        // goto_tab has 8 variants → the param disambiguates in the title.
        let variants = (1...8).map { "goto_tab:\($0)" }
        let fold = ActionLabelCatalog.multiParamActions(in: variants + ["copy_to_clipboard:mixed"])
        XCTAssertEqual(ActionLabelCatalog.bundled.displayTitle(for: "goto_tab:1", foldingParamsFor: fold),
                       "Go to tab (1)")
        // copy_to_clipboard:mixed is the sole variant → title stays "Copy", no parenthetical.
        XCTAssertEqual(ActionLabelCatalog.bundled.displayTitle(for: "copy_to_clipboard:mixed", foldingParamsFor: fold),
                       "Copy")
        // A param-less action is unaffected.
        XCTAssertEqual(ActionLabelCatalog.bundled.displayTitle(for: "reload_config", foldingParamsFor: fold),
                       ActionLabelCatalog.bundled.displayTitle(forAction: "reload_config"))
    }

    func testParamFoldDecisionComputedFromTheRealDefaultsFixture() throws {
        // Covers R8: the fold set derived from the shipped 1.3.1 defaults folds goto_tab
        // (params 1…8) but not copy_to_clipboard (only `mixed`).
        let names = KeybindReference.parseActions(try Fixture.text("list-actions", "txt")).map(\.name)
        let defaults = KeybindReference.parseDefaults(try Fixture.text("list-keybinds-default", "txt"),
                                                      knownActions: Set(names))
        let fold = ActionLabelCatalog.multiParamActions(in: defaults.map(\.action))
        XCTAssertTrue(fold.contains("goto_tab"))
        XCTAssertFalse(fold.contains("copy_to_clipboard"))
    }
}
