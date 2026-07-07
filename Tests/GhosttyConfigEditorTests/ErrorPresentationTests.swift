import XCTest
@testable import GhosttyConfigEditor
@testable import GhosttyConfigKit

/// The application-boundary error normalizer (KTD4, R3, U3). A failed write must never
/// surface a raw Ghostty diagnostic or an implementation type name in row feedback; the
/// raw text stays available as secondary `detail` for troubleshooting.
final class ErrorPresentationTests: XCTestCase {

    // Scenario 4: `error.InvalidCharacter` in a color editor becomes a plain invalid-color
    // message, with the raw diagnostic retained as detail.
    func testInvalidCharacterDiagnosticMapsToPlainColorMessageWithRawRetained() {
        let raw = "error.InvalidCharacter"
        let error = ConfigWriteError.validationFailed([
            ValidationMessage(file: nil, line: nil, key: "background", message: raw)
        ])
        let p = EditErrorPresentation.present(error, kind: .color)
        XCTAssertEqual(p.message, "That isn't a valid color.")
        XCTAssertEqual(p.detail, raw)                    // raw retained for troubleshooting
        assertNoImplementationName(p.message)
    }

    // The `unknown error ` noise prefix Ghostty sometimes emits is stripped, not surfaced.
    func testUnknownErrorPrefixedDiagnosticIsStrippedAndNormalized() {
        let raw = "unknown error error.InvalidCharacter"
        let error = ConfigWriteError.validationFailed([
            ValidationMessage(file: nil, line: nil, key: nil, message: raw)
        ])
        let p = EditErrorPresentation.present(error, kind: .color)
        XCTAssertEqual(p.message, "That isn't a valid color.")
        XCTAssertFalse(p.message.lowercased().contains("unknown error"))
        assertNoImplementationName(p.message)
    }

    // The same diagnostic in a non-color context avoids color-specific wording.
    func testGenericContextInvalidCharacterAvoidsColorWording() {
        let error = ConfigWriteError.validationFailed([
            ValidationMessage(file: nil, line: nil, key: nil, message: "error.InvalidCharacter")
        ])
        let p = EditErrorPresentation.present(error, kind: .generic)
        assertNoImplementationName(p.message)
        XCTAssertFalse(p.message.lowercased().contains("color"))
    }

    func testStaleOnDiskOffersReloadWithPlainMessage() {
        let p = EditErrorPresentation.present(ConfigWriteError.staleOnDisk(path: "/tmp/config"))
        XCTAssertTrue(p.offersReload)                    // the fix is a reload, so the surface can offer it
        XCTAssertFalse(p.message.isEmpty)
        assertNoImplementationName(p.message)
    }

    func testInvalidValueMapsToLineBreakMessage() {
        let p = EditErrorPresentation.present(ConfigWriteError.invalidValue("a\nb"))
        XCTAssertFalse(p.offersReload)
        assertNoImplementationName(p.message)
    }

    // Every ConfigWriteError case yields a plain message that hides its implementation type.
    func testEveryConfigWriteErrorCaseYieldsPlainMessageWithoutImplName() {
        let cases: [ConfigWriteError] = [
            .staleOnDisk(path: "/tmp/config"),
            .validationFailed([ValidationMessage(file: nil, line: nil, key: nil, message: "bad")]),
            .backupFailed("Error Domain=NSCocoaErrorDomain Code=512"),
            .stageFailed("EACCES"),
            .renameFailed("EPERM"),
            .invalidValue("x\ny"),
        ]
        for c in cases {
            let p = EditErrorPresentation.present(c)
            XCTAssertFalse(p.message.isEmpty)
            assertNoImplementationName(p.message)
        }
    }

    // An arbitrary Swift error is caught at the boundary too — no raw description headline.
    func testGenericSwiftErrorDoesNotLeakRawDescriptionAsHeadline() {
        struct Boom: Error {}
        let p = EditErrorPresentation.present(Boom())
        XCTAssertFalse(p.message.isEmpty)
        assertNoImplementationName(p.message)
        XCTAssertFalse(p.message.contains("Boom"))
    }

    /// No UI-facing message may print a Swift/Zig implementation type name (KTD4/R3).
    private func assertNoImplementationName(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for token in ["ConfigWriteError", "error.", "NSCocoaErrorDomain", "Optional(", "Error Domain"] {
            XCTAssertFalse(message.contains(token), "message leaked '\(token)': \(message)", file: file, line: line)
        }
    }
}
