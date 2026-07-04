import XCTest
@testable import GhosttyConfigKit

/// U3 (CM-3): DocFormatter reflows hard-wrapped paragraphs (healing mid-token breaks)
/// and lifts `* ` items into bullets — deliberately not full Markdown.
final class DocFormatterTests: XCTestCase {

    func testReflowHealsAMidTokenBreak() {
        // A code span split across a hard wrap (`CSI` / `q`) must rejoin to `CSI q`.
        let doc = [
            "The style of the cursor. A running program can request a style using escape",
            "sequences (such as `CSI",
            "q`). Shell configs often request styles.",
        ].joined(separator: "\n")

        let blocks = DocFormatter.format(doc)
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let text)? = blocks.first else { return XCTFail("expected one paragraph") }
        XCTAssertTrue(text.contains("`CSI q`"), "mid-token break not healed: \(text)")
        XCTAssertFalse(text.contains("\n"))
    }

    func testValidValuesRenderAsBullets() {
        let doc = [
            "The style of the cursor.",
            "",
            "Valid values are:",
            "",
            "  * `block`",
            "  * `bar`",
            "  * `underline`",
            "  * `block_hollow`",
        ].joined(separator: "\n")

        XCTAssertEqual(DocFormatter.format(doc), [
            .paragraph("The style of the cursor."),
            .paragraph("Valid values are:"),
            .bullet("`block`"),
            .bullet("`bar`"),
            .bullet("`underline`"),
            .bullet("`block_hollow`"),
        ])
    }

    func testBlankLinesSeparateParagraphs() {
        let doc = "First paragraph\nwrapped.\n\nSecond paragraph."
        XCTAssertEqual(DocFormatter.format(doc), [
            .paragraph("First paragraph wrapped."),
            .paragraph("Second paragraph."),
        ])
    }

    func testIndentedContinuationFoldsIntoPrecedingBullet() {
        let doc = [
            "  * `linear` - blend in linear space. This",
            "    eliminates fringing.",
            "  * `native` - blend in the OS color space.",
        ].joined(separator: "\n")

        XCTAssertEqual(DocFormatter.format(doc), [
            .bullet("`linear` - blend in linear space. This eliminates fringing."),
            .bullet("`native` - blend in the OS color space."),
        ])
    }

    func testEmptyOrBlankDocumentationYieldsNoBlocks() {
        XCTAssertEqual(DocFormatter.format(""), [])
        XCTAssertEqual(DocFormatter.format("   \n  \n"), [])
    }
}
