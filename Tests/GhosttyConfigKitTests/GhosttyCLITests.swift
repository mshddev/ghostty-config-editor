import XCTest
@testable import GhosttyConfigKit

/// Subprocess timeout behavior (review G1): a wedged binary must not hang the
/// caller forever — the watchdog kills it and surfaces `.timedOut`.
final class GhosttyCLITests: XCTestCase {

    func testRunCapturesStdoutAndExitCode() async throws {
        let echo = GhosttyCLI(binaryPath: "/bin/echo")
        let result = try await echo.run(["hello"])
        XCTAssertEqual(result.stdoutString, "hello\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.succeeded)
    }

    func testRunTimesOutOnAHangingBinary() async {
        // `/bin/sleep 5` far outlives the 0.5s deadline; the watchdog must kill
        // it and surface `.timedOut` quickly rather than blocking for 5 seconds.
        let sleeper = GhosttyCLI(binaryPath: "/bin/sleep")
        let start = Date()
        do {
            _ = try await sleeper.run(["5"], timeout: 0.5)
            XCTFail("expected a timeout")
        } catch GhosttyCLIError.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(start), 3.0,
                              "must abandon well before the 5s sleep would finish")
        } catch {
            XCTFail("expected .timedOut, got \(error)")
        }
    }

    func testRunCompletesNormallyWellWithinTimeout() async throws {
        // A fast command with a generous deadline must not be affected by the watchdog.
        let echo = GhosttyCLI(binaryPath: "/bin/echo")
        let result = try await echo.run(["ok"], timeout: 5)
        XCTAssertEqual(result.stdoutString, "ok\n")
    }
}
