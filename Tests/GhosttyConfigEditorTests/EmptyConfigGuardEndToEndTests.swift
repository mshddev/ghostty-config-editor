import XCTest
@testable import GhosttyConfigEditor
@testable import GhosttyConfigKit

/// A · would-be-empty write — **end-to-end**. The unit tests in `ConfigWriterTests` prove the
/// `ConfigWriter` guard in isolation (`cli: nil`); these boot a **real** `AppModel` against a
/// throwaway `XDG_CONFIG_HOME` and drive the actual user paths — unsetting the last option and
/// importing empty text — through the installed binary. They assert the feedback the user ends
/// up seeing on the row is the clear "can't be empty" message, NOT the opaque
/// "The change didn't validate." that Ghostty's diagnostic-free zero-byte rejection produced
/// before the fix — and that the live config file is left byte-intact.
///
/// Gated by `GHOSTTY_LIVE_TESTS` like the rest of the live suite (booting a real model needs
/// the binary for discovery + catalog); bootstrapping against a throwaway `XDG_CONFIG_HOME`
/// guarantees the user's real config is never read or written.
@MainActor
final class EmptyConfigGuardEndToEndTests: XCTestCase {

    private let clearMessage =
        "A config file can't be empty. Reset options to defaults instead of clearing the file."

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GHOSTTY_LIVE_TESTS"] != nil,
                          "Live ghostty tests are disabled; set GHOSTTY_LIVE_TESTS=1 to run them.")
    }

    /// Unsetting the last remaining option on a file with no trailing newline would leave a
    /// zero-byte config. The real apply path must surface the clear message and leave the file.
    func testUnsettingTheLastOptionSurfacesTheClearMessage() async throws {
        let ctx = try await bootModel(starter: "font-size = 12")   // no trailing newline
        defer { ctx.cleanup() }
        let model = ctx.model

        let option = try XCTUnwrap(model.browser?.merged.option(named: "font-size"),
                                   "font-size must be present in the catalog")
        await model.applyEdit(option: option, values: [])          // unset the only option

        guard case .failed(let presentation) = model.applyState else {
            return XCTFail("emptying the config should land in .failed, got \(model.applyState)")
        }
        XCTAssertEqual(presentation.message, clearMessage,
                       "the user must see the clear message, not \"The change didn't validate.\"")
        // The guard fires before any write — the live config is byte-intact.
        XCTAssertEqual(try String(contentsOf: ctx.configURL, encoding: .utf8), "font-size = 12")
    }

    /// Importing empty text is the other realistic way to zero out the file; it must be
    /// rejected with the same clear message, config untouched.
    func testImportingEmptyTextSurfacesTheClearMessage() async throws {
        let ctx = try await bootModel(starter: "font-size = 12\n")
        defer { ctx.cleanup() }
        let model = ctx.model

        await model.importConfig(text: "")

        guard case .failed(let presentation) = model.applyState else {
            return XCTFail("importing empty text should land in .failed, got \(model.applyState)")
        }
        XCTAssertEqual(presentation.message, clearMessage)
        XCTAssertEqual(try String(contentsOf: ctx.configURL, encoding: .utf8), "font-size = 12\n")
    }

    // MARK: - Harness

    private struct BootContext {
        let model: AppModel
        let configURL: URL
        let tempDir: URL
        let priorXDG: String?
        func cleanup() {
            if let priorXDG { setenv("XDG_CONFIG_HOME", priorXDG, 1) } else { unsetenv("XDG_CONFIG_HOME") }
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// Boot a real `AppModel` against a throwaway `XDG_CONFIG_HOME/ghostty/config` seeded with
    /// `starter`, using the installed binary for discovery, catalog, and validation. Skips
    /// (rather than fails) if the environment doesn't load.
    private func bootModel(starter: String) async throws -> BootContext {
        let priorXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gce-empty-\(UUID().uuidString)")
        let ghosttyDir = tempDir.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        let configURL = ghosttyDir.appendingPathComponent("config")
        try Data(starter.utf8).write(to: configURL)
        setenv("XDG_CONFIG_HOME", tempDir.path, 1)

        let model = AppModel()
        await model.bootstrap()
        let ctx = BootContext(model: model, configURL: configURL, tempDir: tempDir, priorXDG: priorXDG)
        guard model.contentState == .loaded else {
            ctx.cleanup()
            throw XCTSkip("Ghostty environment did not load (\(model.contentState)); skipping live test.")
        }
        return ctx
    }
}
