import XCTest
@testable import GhosttyConfigKit

/// The pure edit-transaction reducer (KTD2, U3). Covers the lifecycle transitions the
/// text-bearing popovers rely on: Clean → Dirty ↔ Invalid → Applying → Committed |
/// Stale | Failed, plus Stale → (Reload & Review) → reviewable Dirty. No SwiftUI — this
/// is the tested state machine the color / long-value editors wrap the safe-write path
/// with. Scenario numbers refer to the U3 test list.
final class EditTransactionTests: XCTestCase {

    // Scenario 1: an invalid draft can never write, and Cancel / incidental dismissal
    // discards it and keeps the saved value (AE2 at the reducer level).
    func testInvalidDraftThenCancelPerformsNoWriteAndRetainsSaved() {
        var t = EditTransaction(savedValue: "#1e1e2e")
        t.edit("#zzzzzz", locallyValid: false, invalidMessage: "That isn't a valid color.")
        XCTAssertTrue(t.isLocallyInvalid)
        XCTAssertFalse(t.canApply)                       // invalid → nothing to apply → no write
        XCTAssertEqual(t.message, "That isn't a valid color.")
        XCTAssertFalse(t.beginApply())                   // Apply refuses an invalid draft
        XCTAssertFalse(t.isApplying)
        t.cancel()                                       // Escape / click-outside follows Cancel
        XCTAssertEqual(t.phase, .clean)
        XCTAssertEqual(t.draft, "#1e1e2e")
        XCTAssertNil(t.message)
    }

    // Scenario 2: a settled valid draft applies exactly once even though the color wheel
    // fired many draft callbacks landing on the same value.
    func testValidDraftAppliesOnceDespiteMultipleDraftCallbacks() {
        var t = EditTransaction(savedValue: "#000000")
        t.edit("#111111")
        t.edit("#101010")
        t.edit("#111111")
        XCTAssertTrue(t.isDirty)
        XCTAssertTrue(t.canApply)
        XCTAssertTrue(t.beginApply())                    // the ONE write starts
        XCTAssertTrue(t.isApplying)
        XCTAssertFalse(t.canApply)                       // nothing more to start while applying
        XCTAssertFalse(t.beginApply())                   // a trailing callback / double-Apply no-ops
        t.markCommitted()
        XCTAssertTrue(t.isCommitted)
        XCTAssertEqual(t.savedValue, "#111111")

        // Committed → Clean once the model refreshes the saved value (lifecycle diagram).
        t.finishCommit()
        XCTAssertEqual(t.phase, .clean)
        XCTAssertFalse(t.canApply)
        XCTAssertEqual(t.draft, "#111111")
    }

    // Scenario 3: Cancel discards a dirty valid draft; Apply commits it.
    func testCancelDiscardsDirtyDraftWhileApplyCommitsIt() {
        var cancelled = EditTransaction(savedValue: "16")
        cancelled.edit("18")
        XCTAssertTrue(cancelled.canApply)
        cancelled.cancel()
        XCTAssertEqual(cancelled.draft, "16")
        XCTAssertEqual(cancelled.phase, .clean)

        var applied = EditTransaction(savedValue: "16")
        applied.edit("18")
        XCTAssertTrue(applied.beginApply())
        applied.markCommitted()
        XCTAssertEqual(applied.savedValue, "18")
    }

    // Scenario 3 (discrete/immediate corollary): a clean transaction never applies, and
    // editing back to the exact saved value returns to Clean (nothing to write).
    func testCleanTransactionCannotApply() {
        var t = EditTransaction(savedValue: "bar")
        XCTAssertFalse(t.canApply)
        XCTAssertFalse(t.beginApply())
        t.edit("baz")
        t.edit("bar")
        XCTAssertEqual(t.phase, .clean)
        XCTAssertFalse(t.canApply)
    }

    // Failed → Dirty: the rejected draft is retained (no retype) and correcting it re-arms Apply.
    func testFailedRetainsDraftAndEditingReturnsToDirty() {
        var t = EditTransaction(savedValue: "#1e1e2e")
        t.edit("tomato-typo")
        XCTAssertTrue(t.beginApply())
        t.markFailed(message: "That isn't a valid color.")
        XCTAssertTrue(t.isFailed)
        XCTAssertEqual(t.draft, "tomato-typo")           // retained (R3)
        XCTAssertFalse(t.canApply)
        t.edit("#abcdef")
        XCTAssertTrue(t.isDirty)
        XCTAssertTrue(t.canApply)
        XCTAssertNil(t.message)
    }

    // Scenario 5 (AE3): a stale write retains the draft, Reload & Review shows the
    // refreshed disk value beside it, and only a SECOND explicit Apply commits.
    func testStaleReloadAndReviewRetainsDraftShowsBothAndRequiresSecondApply() {
        var t = EditTransaction(savedValue: "16")
        t.edit("17")
        XCTAssertTrue(t.beginApply())
        t.markStale(message: "This file changed on disk since it was read.")
        XCTAssertTrue(t.isStale)
        XCTAssertEqual(t.draft, "17")                    // retained through stale (R5)
        XCTAssertFalse(t.canApply)                       // NEVER auto-retries while stale

        t.reloadAndReview(refreshedDiskValue: "18")
        XCTAssertTrue(t.isDirty)
        XCTAssertEqual(t.draft, "17")                    // still the attempted value — no retype
        XCTAssertEqual(t.savedValue, "18")               // the externally-changed disk value
        XCTAssertEqual(t.refreshedDiskValue, "18")       // available for the side-by-side review
        XCTAssertTrue(t.canApply)                        // a second explicit Apply is possible

        XCTAssertTrue(t.beginApply())
        t.markCommitted()
        XCTAssertEqual(t.savedValue, "17")               // the retained draft wins on the 2nd apply
    }

    // Reload & Review that finds the draft already matches disk resolves to Clean (no write).
    func testReloadAndReviewResolvesWhenDraftMatchesDisk() {
        var t = EditTransaction(savedValue: "16")
        t.edit("18")
        _ = t.beginApply()
        t.markStale()
        t.reloadAndReview(refreshedDiskValue: "18")      // external edit already set what we wanted
        XCTAssertEqual(t.phase, .clean)
        XCTAssertFalse(t.canApply)
        XCTAssertNil(t.refreshedDiskValue)
    }

    // Scenario 6: if the option disappears after reload, review stops with an actionable
    // message and Apply is disabled rather than guessing a target.
    func testTargetDisappearingAfterReloadDisablesApplyWithMessage() {
        var t = EditTransaction(savedValue: "17")
        t.edit("18")
        _ = t.beginApply()
        t.markStale()
        t.markTargetUnavailable(message: "This setting is no longer in your config.")
        XCTAssertFalse(t.isTargetAvailable)
        XCTAssertFalse(t.canApply)                       // Apply disabled — never guesses
        XCTAssertEqual(t.draft, "18")                    // draft retained for the message context
        XCTAssertEqual(t.message, "This setting is no longer in your config.")
    }

    // Scenario 7: an edit + reviewed apply of one option never touches a different
    // option's independent transaction (the reducer carries only its own value).
    func testEditingOneOptionLeavesADifferentOptionsTransactionIntact() {
        var fontSize = EditTransaction(savedValue: "16")
        var background = EditTransaction(savedValue: "#1e1e2e")   // a DIFFERENT option

        fontSize.edit("17")
        _ = fontSize.beginApply()
        fontSize.markStale()
        fontSize.reloadAndReview(refreshedDiskValue: "16")
        _ = fontSize.beginApply()
        fontSize.markCommitted()
        XCTAssertEqual(fontSize.savedValue, "17")

        XCTAssertEqual(background.phase, .clean)
        XCTAssertEqual(background.draft, "#1e1e2e")
        XCTAssertEqual(background.savedValue, "#1e1e2e")
        XCTAssertFalse(background.canApply)
    }
}
