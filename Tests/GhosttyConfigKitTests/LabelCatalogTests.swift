import XCTest
@testable import GhosttyConfigKit

final class LabelCatalogTests: XCTestCase {

    // MARK: - humanize

    func testHumanizeIsSentenceCase() {
        XCTAssertEqual(LabelCatalog.humanize("adjust-cell-height"), "Adjust cell height")
    }

    func testHumanizeKeepsKnownAcronymsCased() {
        XCTAssertEqual(LabelCatalog.humanize("macos-titlebar-style"), "macOS titlebar style")
        XCTAssertEqual(LabelCatalog.humanize("gtk-titlebar"), "GTK titlebar")
        XCTAssertEqual(LabelCatalog.humanize("osc-color-report-format"), "OSC color report format")
    }

    func testHumanizeSingleWord() {
        XCTAssertEqual(LabelCatalog.humanize("theme"), "Theme")
    }

    // MARK: - firstSentence

    func testFirstSentenceTruncatesAtSentenceBoundary() {
        XCTAssertEqual(
            LabelCatalog.firstSentence("Font size in points. Must be positive."),
            "Font size in points."
        )
    }

    func testFirstSentenceCapsLengthOnWordBoundary() {
        let long = String(repeating: "word ", count: 60) // ~300 chars, no sentence boundary
        let summary = LabelCatalog.firstSentence(long, maxLength: 120)
        XCTAssertLessThanOrEqual(summary.count, 121)
        XCTAssertTrue(summary.hasSuffix("…"))
    }

    func testFirstSentenceEmptyForBlankDocs() {
        XCTAssertEqual(LabelCatalog.firstSentence(""), "")
        XCTAssertEqual(LabelCatalog.firstSentence("   \n  "), "")
    }

    // MARK: - displayTitle / shortSummary precedence

    func testCuratedTitleWinsOverHumanizer() {
        XCTAssertEqual(LabelCatalog.bundled.displayTitle(for: "font-family"), "Font")
    }

    func testAbsentNameStillYieldsNonEmptyTitle() {
        let title = LabelCatalog.bundled.displayTitle(for: "some-unknown-option-xyz")
        XCTAssertFalse(title.isEmpty)
        XCTAssertEqual(title, "Some unknown option xyz")
    }

    func testShortSummaryPrefersCuratedThenDocsThenEmpty() {
        // Curated summary wins even when docs are present.
        XCTAssertEqual(
            LabelCatalog.bundled.shortSummary(for: "font-family", documentation: "ignored docs."),
            "The typeface used for terminal text."
        )
        // No curated summary → first sentence of the docs.
        let catalog = LabelCatalog(curated: ["x": .init(title: "X", summary: nil)])
        XCTAssertEqual(catalog.shortSummary(for: "x", documentation: "Hello world. More text."), "Hello world.")
        // Neither → empty.
        XCTAssertEqual(catalog.shortSummary(for: "x", documentation: ""), "")
    }

    // MARK: - parity + orphan guards (against the real captured catalog)

    func testRawKeySearchStillMatchesAfterRelabeling() throws {
        // R8: a power user who types the raw config key must still find the option,
        // even though the row now renders a friendly label.
        let search = CatalogSearch(catalog: try referenceCatalog())
        XCTAssertEqual(search.search("background-opacity").first?.optionName, "background-opacity")
        XCTAssertEqual(search.search("macos-titlebar-style").first?.optionName, "macos-titlebar-style")
    }

    func testEveryCuratedKeyResolvesInReferenceCatalog() throws {
        // KTD1: a curated key that no longer exists in the catalog (renamed/removed
        // on a Ghostty upgrade) must fail loudly rather than silently dangle.
        let names = Set(try referenceCatalog().options.map(\.name))
        let orphans = LabelCatalog.bundled.curatedOptionNames.subtracting(names)
        XCTAssertTrue(orphans.isEmpty, "option-labels.json has keys absent from the catalog: \(orphans.sorted())")
    }

    func testEveryOptionHasNonEmptyDisplayTitle() throws {
        for option in try referenceCatalog().options {
            XCTAssertFalse(option.displayTitle.isEmpty, "empty displayTitle for \(option.name)")
        }
    }

    private func referenceCatalog() throws -> OptionCatalog {
        CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"))
    }
}
