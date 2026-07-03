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
}
