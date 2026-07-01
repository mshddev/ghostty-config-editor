import Foundation
import XCTest
@testable import GhosttyConfigKit

/// Gate for tests that shell out to the **real** installed `ghostty` binary.
///
/// Off by default so `swift test` is hermetic and deterministic. The real binary
/// is machine-dependent (a running GUI instance, forked helpers, GPU/font init)
/// and, historically, could hang the suite: a leaked stdout write-end left the
/// old read-to-EOF drain blocking forever, wedging whichever live test happened
/// to run. `GhosttyCLI.run` is now deadline-bounded, but these tests still assert
/// against a binary whose behavior we don't control, so they stay opt-in.
///
/// Enable with `GHOSTTY_LIVE_TESTS=1` (CI sets this to exercise the live paths);
/// `GHOSTTY_BIN` can point at a non-standard install.
enum LiveGhostty {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["GHOSTTY_LIVE_TESTS"] != nil
    }

    /// Skip the calling test unless live ghostty tests are enabled.
    static func skipUnlessEnabled(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(isEnabled,
                          "Live ghostty tests are disabled; set GHOSTTY_LIVE_TESTS=1 to run them.",
                          file: file, line: line)
    }
}

extension BinaryLocator {
    /// Locate `ghostty` for tests WITHOUT the login-shell fallback. The real
    /// `zsh -lc` probe is environment-dependent and can be very slow on CI
    /// runners, which would dominate (and previously hung) the suite. Tests only
    /// need to know whether a usable binary exists at a standard path; a
    /// `GHOSTTY_BIN` env override lets CI point at a custom location.
    ///
    /// Returns `nil` unless `LiveGhostty.isEnabled` — so live tests that gate on
    /// a located binary skip by default and the hermetic suite never spawns the
    /// real, machine-dependent binary.
    static func locateForTests() -> String? {
        guard LiveGhostty.isEnabled else { return nil }
        return locate(
            userOverride: ProcessInfo.processInfo.environment["GHOSTTY_BIN"],
            isExecutable: systemIsExecutable,
            shellFallback: { nil }
        )
    }
}

/// Loads real captured Ghostty CLI output staged under `Fixtures/`.
enum Fixture {
    static func text(_ name: String, _ ext: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = try url(name, ext, file: file, line: line)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func url(_ name: String, _ ext: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
            return url
        }
        if let base = Bundle.module.resourceURL {
            let candidate = base.appendingPathComponent("Fixtures/\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        XCTFail("Missing fixture \(name).\(ext)", file: file, line: line)
        throw CocoaError(.fileNoSuchFile)
    }
}
