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

    // MARK: - Health summary for the top-bar chip (R15, R16)

    private func finding(_ severity: LintFinding.Severity) -> LintFinding {
        LintFinding(rule: "r", severity: severity, title: "t", message: "m", locations: [])
    }

    private func completed(isValid: Bool, errors: Int) -> ValidationOutcome {
        let messages = (0..<errors).map {
            ValidationMessage(file: nil, line: nil, key: nil, message: "e\($0)")
        }
        return .completed(ValidationResult(isValid: isValid, messages: messages, rawOutput: ""))
    }

    func testHealthIsCleanWhenNotRunWithNoFindings() {
        let report = LintReport(validation: .notRun, findings: [])
        XCTAssertEqual(report.health, .clean)
        XCTAssertEqual(report.problemCount, 0)
    }

    func testHealthIsCleanWhenValidatedWithNoFindings() {
        let report = LintReport(validation: completed(isValid: true, errors: 0), findings: [])
        XCTAssertEqual(report.health, .clean)
        XCTAssertEqual(report.problemCount, 0)
    }

    func testHealthIsWarningOnFootgunWarning() {
        let report = LintReport(validation: completed(isValid: true, errors: 0),
                                findings: [finding(.warning)])
        XCTAssertEqual(report.health, .warning)
        XCTAssertEqual(report.problemCount, 1)
    }

    func testHealthIgnoresInfoFindings() {
        let report = LintReport(validation: completed(isValid: true, errors: 0),
                                findings: [finding(.info)])
        XCTAssertEqual(report.health, .clean)
        XCTAssertEqual(report.problemCount, 0)
    }

    func testHealthErrorOutranksWarningAndCountsBoth() {
        let report = LintReport(validation: completed(isValid: false, errors: 2),
                                findings: [finding(.warning)])
        XCTAssertEqual(report.health, .error)
        XCTAssertEqual(report.problemCount, 3)
    }

    func testHealthIsUnknownWhenValidationUnavailableAndNothingActionable() {
        let report = LintReport(validation: .unavailable("boom"), findings: [])
        XCTAssertEqual(report.health, .unknown)
        XCTAssertEqual(report.problemCount, 0)
        XCTAssertEqual(report.badgeText, "Health unknown")
    }

    func testFootgunSurfacesAsWarningEvenWhenValidationUnavailable() {
        // Footgun lint is static — it doesn't need the validation binary — so an
        // actionable footgun must surface as .warning rather than being masked
        // behind "Health unknown" when ghostty +validate-config couldn't run.
        let report = LintReport(validation: .unavailable("boom"),
                                findings: [finding(.warning)])
        XCTAssertEqual(report.health, .warning)
        XCTAssertEqual(report.problemCount, 1)
        XCTAssertEqual(report.badgeText, "1 problem")
    }

    func testHealthStaysUnknownWhenUnavailableWithOnlyInfoFinding() {
        // .info findings are not actionable, so they don't lift .unknown to .warning.
        let report = LintReport(validation: .unavailable("boom"),
                                findings: [finding(.info)])
        XCTAssertEqual(report.health, .unknown)
        XCTAssertEqual(report.problemCount, 0)
    }

    func testHealthIsWarningWhenNotRunWithFootgun() {
        let report = LintReport(validation: .notRun, findings: [finding(.warning)])
        XCTAssertEqual(report.health, .warning)
        XCTAssertEqual(report.problemCount, 1)
    }

    func testHealthErrorWithoutParsedMessagesStillCountsOne() {
        // A failed validation that emitted nothing parseable is still .error;
        // problemCount must be >= 1 so the chip never reads a red "0 problems".
        let report = LintReport(validation: completed(isValid: false, errors: 0), findings: [])
        XCTAssertEqual(report.health, .error)
        XCTAssertEqual(report.problemCount, 1)
    }

    // MARK: - Chip label (badgeText)

    func testBadgeTextClean() {
        let report = LintReport(validation: .notRun, findings: [])
        XCTAssertEqual(report.badgeText, "No problems")
    }

    func testBadgeTextSingularAndPlural() {
        let one = LintReport(validation: completed(isValid: true, errors: 0),
                             findings: [finding(.warning)])
        XCTAssertEqual(one.badgeText, "1 problem")
        let many = LintReport(validation: completed(isValid: true, errors: 0),
                              findings: [finding(.warning), finding(.warning)])
        XCTAssertEqual(many.badgeText, "2 problems")
    }

    func testBadgeTextErrorWithoutMessagesReadsOneProblem() {
        let report = LintReport(validation: completed(isValid: false, errors: 0), findings: [])
        XCTAssertEqual(report.badgeText, "1 problem")
    }

    func testBadgeTextUnknown() {
        let report = LintReport(validation: .unavailable("boom"), findings: [])
        XCTAssertEqual(report.badgeText, "Health unknown")
    }
}
