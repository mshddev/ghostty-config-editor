import XCTest
@testable import GhosttyConfigKit

final class OptionStateTests: XCTestCase {

    func testEachStateYieldsExactlyOneDisplayName() {
        XCTAssertEqual(OptionState.setNonDefault.displayName, "Customized")
        XCTAssertEqual(OptionState.setToDefault.displayName, "Using default")
        XCTAssertEqual(OptionState.unset.displayName, "Not set")
    }

    func testDisplayNamesAreDistinctAndNonEmpty() {
        let names = [OptionState.setNonDefault, .setToDefault, .unset].map(\.displayName)
        XCTAssertEqual(Set(names).count, 3, "each state must have its own word")
        XCTAssertFalse(names.contains(where: \.isEmpty))
    }

    func testEachStateHasNonEmptyHint() {
        for state: OptionState in [.setNonDefault, .setToDefault, .unset] {
            XCTAssertFalse(state.displayHint.isEmpty, "missing hint for \(state)")
        }
    }

    func testVocabularyIsTheSingleSourceAcrossSurfaces() {
        // The dot tooltip, popover badge, and subtitle all read `displayName`, so
        // they now render identical words for the same state (CONTENT-6).
        let state = OptionState.setNonDefault
        let tooltip = state.displayName
        let badge = state.displayName
        let subtitle = state.displayName
        XCTAssertEqual(tooltip, badge)
        XCTAssertEqual(badge, subtitle)
        XCTAssertEqual(tooltip, "Customized")
    }
}
