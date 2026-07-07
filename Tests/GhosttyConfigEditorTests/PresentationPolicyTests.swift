import XCTest
@testable import GhosttyConfigEditor
@testable import GhosttyConfigKit

final class PresentationPolicyTests: XCTestCase {
    func testExecutableTargetCanBeImportedWithoutLaunchingApplication() {
        XCTAssertGreaterThan(WindowMetrics.contentMaxWidth, 0)
    }
}
