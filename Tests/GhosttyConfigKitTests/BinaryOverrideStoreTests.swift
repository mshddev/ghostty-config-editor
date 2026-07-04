import XCTest
@testable import GhosttyConfigKit

final class BinaryOverrideStoreTests: XCTestCase {

    /// A throwaway suite per test so nothing leaks into the real defaults.
    private func makeStore() -> (BinaryOverrideStore, UserDefaults) {
        let suite = "BinaryOverrideStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (BinaryOverrideStore(defaults: defaults), defaults)
    }

    func testLoadIsNilWhenUnset() {
        let (store, _) = makeStore()
        XCTAssertNil(store.load())
    }

    func testSaveThenLoadRoundTrips() {
        let (store, _) = makeStore()
        store.save("/opt/homebrew/bin/ghostty")
        XCTAssertEqual(store.load(), "/opt/homebrew/bin/ghostty")
    }

    func testSaveTrimsWhitespace() {
        let (store, _) = makeStore()
        store.save("  /usr/local/bin/ghostty \n")
        XCTAssertEqual(store.load(), "/usr/local/bin/ghostty")
    }

    func testBlankPathClearsTheOverride() {
        let (store, _) = makeStore()
        store.save("/opt/homebrew/bin/ghostty")
        store.save("   ")
        XCTAssertNil(store.load(), "A blank path must clear the override (the 'Use auto-detected' path)")
    }

    func testNilPathClearsTheOverride() {
        let (store, _) = makeStore()
        store.save("/opt/homebrew/bin/ghostty")
        store.save(nil)
        XCTAssertNil(store.load())
    }
}
