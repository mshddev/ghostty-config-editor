import XCTest
@testable import GhosttyConfigKit

final class BinaryLocatorTests: XCTestCase {

    private let appBundle = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
    private let homebrew = "/opt/homebrew/bin/ghostty"

    // MARK: - Ordered probe (KTD3, R19)

    func testProbePicksAppBundleWhenPresent() {
        let result = BinaryLocator.locate(
            userOverride: nil,
            isExecutable: { $0 == appBundle },
            shellFallback: { nil }
        )
        XCTAssertEqual(result, appBundle)
    }

    func testUserOverrideOutranksAllStandardPaths() {
        let override = "/Users/me/bin/ghostty"
        let result = BinaryLocator.locate(
            userOverride: override,
            // Both the override and a standard path are executable…
            isExecutable: { $0 == override || $0 == appBundle },
            shellFallback: { nil }
        )
        // …but the override wins.
        XCTAssertEqual(result, override)
    }

    func testHomebrewUsedWhenAppBundleMissing() {
        let result = BinaryLocator.locate(
            userOverride: nil,
            isExecutable: { $0 == homebrew },
            shellFallback: { nil }
        )
        XCTAssertEqual(result, homebrew)
    }

    func testLoginShellFallbackUsedWhenAllStandardPathsMissing() {
        let shellPath = "/custom/prefix/bin/ghostty"
        let result = BinaryLocator.locate(
            userOverride: nil,
            isExecutable: { $0 == shellPath },
            shellFallback: { shellPath }
        )
        XCTAssertEqual(result, shellPath)
    }

    func testAllCandidatesMissingYieldsNotFound() {
        let result = BinaryLocator.locate(
            userOverride: "/nope/ghostty",
            isExecutable: { _ in false },
            shellFallback: { nil }
        )
        XCTAssertNil(result, "No executable candidate should surface the not-found state (R19)")
    }

    func testBlankUserOverrideIsIgnored() {
        let paths = BinaryLocator.candidatePaths(userOverride: "   ")
        XCTAssertEqual(paths, BinaryLocator.standardCandidates)
    }

    func testCandidateOrderingIsOverrideThenStandard() {
        let paths = BinaryLocator.candidatePaths(userOverride: "/x/ghostty")
        XCTAssertEqual(paths.first, "/x/ghostty")
        XCTAssertEqual(Array(paths.dropFirst()), BinaryLocator.standardCandidates)
    }

    // MARK: - Version parsing (R19)

    func testParseVersionFromStandardOutput() {
        // Mirrors real `ghostty +version` output: "Ghostty 1.3.1\n\nVersion".
        XCTAssertEqual(GhosttyCLI.parseVersion("Ghostty 1.3.1\n\nVersion\n  - foo"), "1.3.1")
    }

    func testParseVersionToleratesLeadingWhitespaceAndCase() {
        XCTAssertEqual(GhosttyCLI.parseVersion("  ghostty 1.4.0-pre\n"), "1.4.0-pre")
    }

    func testParseVersionReturnsNilForUnrelatedOutput() {
        XCTAssertNil(GhosttyCLI.parseVersion("command not found"))
        XCTAssertNil(GhosttyCLI.parseVersion(""))
    }

    // MARK: - Subprocess capture (KTD4)

    func testVerboseStdoutCapturedWithoutDeadlock() async throws {
        // 200 KB far exceeds the 64 KB pipe buffer; a read-then-wait runner
        // would deadlock. Concurrent draining must capture the full stream.
        let sh = GhosttyCLI(binaryPath: "/bin/sh")
        let result = try await sh.run(["-c", "head -c 200000 < /dev/zero | tr '\\0' 'a'"])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.count, 200_000)
    }

    func testExitCodeAndStderrAreCaptured() async throws {
        let sh = GhosttyCLI(binaryPath: "/bin/sh")
        let result = try await sh.run(["-c", "echo oops 1>&2; exit 3"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines), "oops")
    }

    func testLaunchFailureThrowsTypedError() async {
        let bogus = GhosttyCLI(binaryPath: "/definitely/not/here/ghostty")
        do {
            _ = try await bogus.run(["+version"])
            XCTFail("Expected a launch failure")
        } catch GhosttyCLIError.launchFailed {
            // expected
        } catch {
            XCTFail("Expected launchFailed, got \(error)")
        }
    }

    // MARK: - System integration (skipped when Ghostty is absent)

    func testSystemDiscoveryFindsLocalGhostty() async throws {
        guard BinaryLocator.systemIsExecutable("/Applications/Ghostty.app/Contents/MacOS/ghostty") else {
            throw XCTSkip("Ghostty not installed at the standard app-bundle path")
        }
        let env = try await GhosttyEnvironment.discover()
        XCTAssertFalse(env.version.isEmpty)
        XCTAssertEqual(env.version.first?.isNumber, true, "Version should start with a digit")
    }
}
