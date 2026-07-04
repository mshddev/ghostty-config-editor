import XCTest
@testable import GhosttyConfigKit

/// U8 (CV-9): the Ligatures toggle is only as trustworthy as the tag arithmetic behind
/// it — so the add/remove diff is asserted directly rather than eyeballed in the UI.
final class FontFeaturesTests: XCTestCase {

    // Default (empty) list reads as ligatures-on.
    func testEmptyListIsLigaturesOn() {
        XCTAssertTrue(FontFeatures.ligaturesEnabled([]))
    }

    // Turning ligatures off on a clean list produces exactly the disable set.
    func testDisablingFromEmptyWritesTheDisableSet() {
        XCTAssertEqual(FontFeatures.disablingLigatures([]), ["-calt", "-liga", "-dlig"])
        XCTAssertFalse(FontFeatures.ligaturesEnabled(["-calt", "-liga", "-dlig"]))
    }

    // Turning off preserves user-added feature tags, appending the disable set after them.
    func testDisablingPreservesUserTags() {
        XCTAssertEqual(FontFeatures.disablingLigatures(["ss01"]),
                       ["ss01", "-calt", "-liga", "-dlig"])
    }

    // Turning on removes *only* the disable tags, keeping a user-added `ss01`.
    func testEnablingRemovesOnlyDisableTagsPreservingUserTags() {
        XCTAssertEqual(FontFeatures.enablingLigatures(["-calt", "ss01", "-liga"]), ["ss01"])
        XCTAssertTrue(FontFeatures.ligaturesEnabled(["ss01"]))
    }

    // A partial disable (only `-calt`) still reads as off, and toggling off then on is
    // idempotent — no duplicate tags, no lost user features.
    func testPartialDisableReadsOffAndRoundTripsCleanly() {
        XCTAssertFalse(FontFeatures.ligaturesEnabled(["ss01", "-calt"]))
        let off = FontFeatures.disablingLigatures(["ss01", "-calt"])
        XCTAssertEqual(off, ["ss01", "-calt", "-liga", "-dlig"])
        XCTAssertEqual(FontFeatures.enablingLigatures(off), ["ss01"])
    }

    // A comma-separated entry (one line, many tags) is handled tag-by-tag, not as an
    // opaque string, so a disable tag hidden inside a list is still recognized/removed.
    func testCommaSeparatedEntryIsSplitPerTag() {
        XCTAssertFalse(FontFeatures.ligaturesEnabled(["-calt, -liga, -dlig"]))
        XCTAssertEqual(FontFeatures.enablingLigatures(["ss01, -calt"]), ["ss01"])
    }

    // Case-insensitive: an upper-cased disable tag is still recognized (Ghostty tags are
    // case-insensitive).
    func testDisableTagMatchIsCaseInsensitive() {
        XCTAssertFalse(FontFeatures.ligaturesEnabled(["-CALT"]))
    }

    // A user's explicit enable tag (`calt`, no minus) is not our disable tag, so it is
    // preserved when turning ligatures off — the disable set is appended alongside it.
    // The two contradict; Ghostty resolves last-wins (the trailing `-calt` disables), and
    // reading the result back correctly reports ligatures off.
    func testEnableTagAndDisableSetCoexistAndReadAsOff() {
        let off = FontFeatures.disablingLigatures(["calt"])
        XCTAssertEqual(off, ["calt", "-calt", "-liga", "-dlig"])
        XCTAssertFalse(FontFeatures.ligaturesEnabled(off))
        // Turning back on strips only the disable tags, leaving the user's `calt`.
        XCTAssertEqual(FontFeatures.enablingLigatures(off), ["calt"])
    }
}
