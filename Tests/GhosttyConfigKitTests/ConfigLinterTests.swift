import XCTest
@testable import GhosttyConfigKit

final class ConfigLinterTests: XCTestCase {

    private let linter = ConfigLinter()

    private func model(_ text: String) -> ConfigModel {
        ConfigModel(primary: ConfigFile.parse(text: text, path: "/tmp/config", resolvedPath: "/tmp/config"))
    }

    // MARK: - AE4: bare keybind clears all (R16)

    func testAE4_BareKeybindWarnsItClearsAll() {
        let findings = linter.lint(model("keybind =\nfont-size = 16"))
        let clears = findings.first { $0.rule == "keybind-clears-all" }
        XCTAssertNotNil(clears)
        XCTAssertEqual(clears?.severity, .warning)
        XCTAssertEqual(clears?.locations.first?.line, 1)
    }

    func testExplicitClearIsInfoNotWarning() {
        let findings = linter.lint(model("keybind = clear"))
        XCTAssertEqual(findings.first?.rule, "keybind-explicit-clear")
        XCTAssertEqual(findings.first?.severity, .info)
    }

    // MARK: - Malformed + conflicting keybinds (R16)

    func testMalformedKeybindWithoutActionIsFlagged() {
        let findings = linter.lint(model("keybind = super+x"))
        XCTAssertEqual(findings.first?.rule, "keybind-malformed")
    }

    func testConflictingKeybindIsFlagged() {
        let cfg = """
        keybind = super+t=new_tab
        keybind = super+t=new_window
        """
        let findings = linter.lint(model(cfg))
        let conflict = findings.first { $0.rule == "keybind-conflict" }
        XCTAssertNotNil(conflict)
        XCTAssertEqual(conflict?.locations.count, 2)
    }

    func testSameTriggerSameActionIsNotAConflict() {
        let cfg = """
        keybind = super+t=new_tab
        keybind = super+t=new_tab
        """
        XCTAssertTrue(linter.lint(model(cfg)).isEmpty)
    }

    // MARK: - Clean config yields nothing

    func testCleanRealConfigYieldsNoWarnings() throws {
        let text = try Fixture.text("user-config", "ghostty")
        XCTAssertTrue(linter.lint(model(text)).isEmpty,
                      "the user's real config (incl. cmd+[=unbind) should be clean")
    }

    func testUnbindActionIsNotMalformed() {
        // `cmd+[=unbind` is a valid trigger=action, not a missing action.
        XCTAssertTrue(linter.lint(model("keybind = cmd+[=unbind")).isEmpty)
    }

    // MARK: - Validation output parsing (R15)

    func testParseValidationErrors() {
        let out = """
        /Users/x/.config/ghostty/config:1:font-size: invalid value "not-a-number"
        /Users/x/.config/ghostty/config:2:bogus-option: unknown field
        """
        let messages = ConfigLinter.parseValidationOutput(out)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].key, "font-size")
        XCTAssertEqual(messages[0].line, 1)
        XCTAssertTrue(messages[0].message.contains("invalid value"))
        XCTAssertEqual(messages[1].key, "bogus-option")
    }

    func testParseValidationToleratesNonStandardLines() {
        let messages = ConfigLinter.parseValidationOutput("something went wrong\n")
        XCTAssertEqual(messages.count, 1)
        XCTAssertNil(messages[0].line)
        XCTAssertEqual(messages[0].message, "something went wrong")
    }

    // MARK: - Live validation (skipped without Ghostty)

    func testLiveValidationCatchesInvalidValue() async throws {
        guard let path = BinaryLocator.locateForTests() else { throw XCTSkip("Ghostty not installed") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("config")
        try "font-size = not-a-number\n".write(to: bad, atomically: true, encoding: .utf8)

        let result = try await linter.validate(cli: GhosttyCLI(binaryPath: path), configFile: bad.path)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.messages.contains { $0.key == "font-size" },
                      "validator should flag the invalid font-size: \(result.rawOutput)")
    }

    // MARK: - Validation outcome distinguishes "clean" from "couldn't run" (G3 #4)

    func testAnalyzeWithoutBinaryReportsNotRun() async {
        let report = await linter.analyze(model: model("font-size = 16\n"), cli: nil)
        XCTAssertEqual(report.validation, .notRun)
    }

    func testAnalyzeSurfacesUnavailableWhenBinaryFails() async {
        // A bogus binary makes `+validate-config` throw; analyze must report it
        // as .unavailable, not swallow it into a false "validated cleanly".
        let bogus = GhosttyCLI(binaryPath: "/definitely/not/here/ghostty")
        let report = await linter.analyze(model: model("font-size = 16\n"), cli: bogus)
        guard case .unavailable = report.validation else {
            return XCTFail("expected .unavailable, got \(report.validation)")
        }
        // A tooling failure is surfaced but is not itself a config "problem".
        XCTAssertFalse(report.hasProblems)
    }
}
