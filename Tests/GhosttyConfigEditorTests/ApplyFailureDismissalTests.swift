import XCTest
@testable import GhosttyConfigEditor
@testable import GhosttyConfigKit

/// A-2 — a rejected apply leaves a **global** `.failed` apply-state that, unlike
/// `.succeeded`, never auto-collapses; cancelling (or blurring away from) the editor used
/// to strand its red error on the row. `AppModel.dismissApplyFailure(forOptionNamed:)`
/// clears it the moment the edit is abandoned, but ONLY for the option that failed — so one
/// editor's cancel can't wipe another's feedback, and a `.succeeded`/`.applying` state (which
/// never matches the `.failed` guard) is left untouched.
///
/// These drive a **real** invalid apply through the installed binary — gated by
/// `GHOSTTY_LIVE_TESTS` like the rest of the live suite — so the failure and its dismissal are
/// the genuine end-to-end path (validate → reject → `.failed` → dismiss), not a poked state.
/// Bootstrapping against a throwaway `XDG_CONFIG_HOME` guarantees the user's real config is
/// never read or written.
@MainActor
final class ApplyFailureDismissalTests: XCTestCase {

    /// A color a user could plausibly type: it clears the color editor's local hex/name gate
    /// (non-empty, no `#`, so `colorDraftLocallyValid` passes) and therefore round-trips to
    /// Ghostty — which rejects it with `invalid value`. A malformed `#hex` would be caught
    /// locally and never reach this global-failure path.
    private let rejectedColor = "notacolor"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GHOSTTY_LIVE_TESTS"] != nil,
                          "Live ghostty tests are disabled; set GHOSTTY_LIVE_TESTS=1 to run them.")
    }

    /// Abandoning the edit that produced the error clears the stranded `.failed` for that
    /// option — the fix for "the error still appears even if I cancel it".
    func testDismissingClearsARejectedColorApplyForThatOption() async throws {
        let ctx = try await bootModel()
        defer { ctx.cleanup() }
        let model = ctx.model

        let option = try XCTUnwrap(model.browser?.merged.option(named: "cursor-color"),
                                   "cursor-color must be present in the catalog")
        await model.applyEdit(option: option, values: [rejectedColor])

        // Precondition: Ghostty genuinely rejected the value, so we hold a real global failure.
        guard case .failed = model.applyState else {
            return XCTFail("a rejected apply should land in .failed, got \(model.applyState)")
        }
        XCTAssertEqual(model.applyingOptionName, "cursor-color")

        // Abandoning the edit for THIS option clears the error the row was showing.
        model.dismissApplyFailure(forOptionNamed: "cursor-color")
        XCTAssertEqual(model.applyState, .idle)
        XCTAssertNil(model.applyingOptionName)
    }

    /// The dismissal is scoped: closing a *different* option's editor must not wipe the
    /// failure the user still needs to see on `cursor-color`.
    func testDismissingADifferentOptionLeavesTheFailureIntact() async throws {
        let ctx = try await bootModel()
        defer { ctx.cleanup() }
        let model = ctx.model

        let option = try XCTUnwrap(model.browser?.merged.option(named: "cursor-color"))
        await model.applyEdit(option: option, values: [rejectedColor])
        guard case .failed = model.applyState else {
            return XCTFail("expected .failed, got \(model.applyState)")
        }

        model.dismissApplyFailure(forOptionNamed: "font-size")   // some other option's editor closing

        guard case .failed = model.applyState else {
            return XCTFail("a different option's dismissal cleared the failure; state is \(model.applyState)")
        }
        XCTAssertEqual(model.applyingOptionName, "cursor-color",
                       "the failure must still belong to cursor-color")
    }

    // MARK: - Harness

    private struct BootContext {
        let model: AppModel
        let tempDir: URL
        let priorXDG: String?
        func cleanup() {
            if let priorXDG { setenv("XDG_CONFIG_HOME", priorXDG, 1) } else { unsetenv("XDG_CONFIG_HOME") }
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// Boot a real `AppModel` against a throwaway `XDG_CONFIG_HOME/ghostty/config` so the test
    /// can never touch the user's actual config, using the installed binary for discovery,
    /// catalog, and validation. Skips (rather than fails) if the environment doesn't load.
    private func bootModel() async throws -> BootContext {
        let priorXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gce-a2-\(UUID().uuidString)")
        let ghosttyDir = tempDir.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        // A non-empty, valid starter avoids the empty-config validation quirk.
        try Data("font-size = 12\n".utf8).write(to: ghosttyDir.appendingPathComponent("config"))
        setenv("XDG_CONFIG_HOME", tempDir.path, 1)

        let model = AppModel()
        await model.bootstrap()
        let ctx = BootContext(model: model, tempDir: tempDir, priorXDG: priorXDG)
        guard model.contentState == .loaded else {
            ctx.cleanup()
            throw XCTSkip("Ghostty environment did not load (\(model.contentState)); skipping live test.")
        }
        return ctx
    }
}
