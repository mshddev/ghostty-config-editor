import Foundation
import XCTest

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
