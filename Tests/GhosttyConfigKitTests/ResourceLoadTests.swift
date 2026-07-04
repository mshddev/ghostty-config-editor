import XCTest
@testable import GhosttyConfigKit

final class ResourceLoadTests: XCTestCase {

    private struct LoadBlewUp: Error {}

    func testCaptureReturnsLoadedOnSuccess() async {
        let state = await ResourceLoad<[String]>.capture { ["Nord", "Dracula"] }
        XCTAssertEqual(state, .loaded(["Nord", "Dracula"]))
        XCTAssertEqual(state.value, ["Nord", "Dracula"])
        XCTAssertFalse(state.isFailed)
        XCTAssertNil(state.failureReason)
    }

    func testCaptureSurfacesADistinctFailedStateWhenTheProviderThrows() async {
        // The core guarantee (G3): a thrown load becomes `.failed`, NOT an empty
        // `.loaded([])` — otherwise the UI can't tell "failed" from "nothing here" and
        // spins forever.
        let state = await ResourceLoad<[String]>.capture { throw LoadBlewUp() }
        XCTAssertTrue(state.isFailed)
        XCTAssertNotEqual(state, .loaded([]))
        XCTAssertNil(state.value)
        XCTAssertNotNil(state.failureReason)
    }

    func testEmptySuccessIsLoadedNotFailed() async {
        // An honestly-empty result is still a success — only a throw is a failure.
        let state = await ResourceLoad<[String]>.capture { [] }
        XCTAssertEqual(state, .loaded([]))
        XCTAssertFalse(state.isFailed)
    }
}
