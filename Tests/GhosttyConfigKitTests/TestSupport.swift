import Foundation
import XCTest
@testable import GhosttyConfigKit

extension BinaryLocator {
    /// Locate `ghostty` for tests WITHOUT the login-shell fallback. The real
    /// `zsh -lc` probe is environment-dependent and can be very slow on CI
    /// runners, which would dominate (and previously hung) the suite. Tests only
    /// need to know whether a usable binary exists at a standard path; a
    /// `GHOSTTY_BIN` env override lets CI point at a custom location.
    static func locateForTests() -> String? {
        locate(
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
