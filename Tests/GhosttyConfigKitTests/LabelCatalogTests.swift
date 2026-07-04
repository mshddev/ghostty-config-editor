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

    // MARK: - title-echo skip (U3, CV-10/CM-5)

    func testShortSummarySkipsATitleEchoingFirstSentence() {
        // Empty curated → humanized title "Background image fit"; the first doc sentence
        // restates it, so the summary must advance to the next real sentence.
        let catalog = LabelCatalog(curated: [:])
        XCTAssertEqual(
            catalog.shortSummary(for: "background-image-fit",
                                 documentation: "Background image fit. Controls how the image is scaled."),
            "Controls how the image is scaled."
        )
    }

    func testShortSummaryIsEmptyWhenDocsAreOnlyATitleEcho() {
        let catalog = LabelCatalog(curated: [:])
        XCTAssertEqual(catalog.shortSummary(for: "background-image-fit", documentation: "Background image fit."), "")
    }

    func testFirstSentenceUnchangedWithoutATitle() {
        // Back-compat: the no-title overload behaves exactly as before.
        XCTAssertEqual(LabelCatalog.firstSentence("Alpha beta. Gamma delta."), "Alpha beta.")
    }

    func testBackgroundImageFitSummaryIsNeverATitleEchoInCatalog() throws {
        let catalog = try referenceCatalog()
        guard let option = catalog.option(named: "background-image-fit") else {
            throw XCTSkip("background-image-fit absent from reference catalog")
        }
        func normalized(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }
        XCTAssertNotEqual(normalized(option.shortSummary), normalized(option.displayTitle),
                          "summary echoes the title for background-image-fit")
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

    // MARK: - exampleValue (B4)

    func testExampleValuePullsFirstBacktickToken() {
        let doc = "The terminal type. Set to `xterm-256color` for wide compatibility."
        XCTAssertEqual(LabelCatalog.exampleValue(from: doc, excluding: "term"), "xterm-256color")
    }

    func testExampleValueSkipsTheOptionsOwnName() {
        let doc = "`command` runs at startup, e.g. `/bin/zsh -l`."
        XCTAssertEqual(LabelCatalog.exampleValue(from: doc, excluding: "command"), "/bin/zsh -l")
    }

    func testExampleValueEmptyWhenNoUsableToken() {
        XCTAssertEqual(LabelCatalog.exampleValue(from: "Plain prose, no code spans.", excluding: ""), "")
        XCTAssertEqual(LabelCatalog.exampleValue(from: "", excluding: ""), "")
    }

    func testExampleValueBailsOnUnbalancedBacktick() {
        // An unclosed backtick must not let unpaired prose be mined as an example.
        XCTAssertEqual(LabelCatalog.exampleValue(from: "Use `xterm here without closing", excluding: ""), "")
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

    // MARK: - U7 field placeholder fallback (CV-7)

    // A concrete docs example wins — the field hints at the *shape* of a valid value
    // (the first balanced backtick token, mirroring `exampleValue`).
    func testFieldPlaceholderPrefersDocsExample() {
        let placeholder = LabelCatalog.fieldPlaceholder(
            name: "term", title: "Terminal type",
            documentation: "The terminal type to advertise, e.g. `xterm-256color`.", defaultValue: "")
        XCTAssertEqual(placeholder, "xterm-256color")
    }

    // No example → the default value hints instead (surrounding quotes stripped).
    func testFieldPlaceholderFallsBackToStrippedDefault() {
        let placeholder = LabelCatalog.fieldPlaceholder(
            name: "font-family", title: "Font", documentation: "No backticked value here.",
            defaultValue: "\"Menlo\"")
        XCTAssertEqual(placeholder, "Menlo")
    }

    // No example and no default → a title-derived prompt, never a bare "value" (CV-7).
    func testFieldPlaceholderFallsBackToTitlePrompt() {
        let placeholder = LabelCatalog.fieldPlaceholder(
            name: "background-image", title: "Background image", documentation: "", defaultValue: "")
        XCTAssertEqual(placeholder, "Enter a background image")
    }

    // The article agrees with the title's first letter.
    func testTitlePromptUsesAnForVowelInitialTitles() {
        let placeholder = LabelCatalog.fieldPlaceholder(
            name: "adjustment", title: "Adjustment", documentation: "", defaultValue: "")
        XCTAssertEqual(placeholder, "Enter an adjustment")
    }

    // A typed field opts out of example mining, so a stray backtick token in the docs
    // never becomes a number field's placeholder — it falls straight through to default.
    func testFieldPlaceholderSkipsExampleWhenMiningDisabled() {
        let placeholder = LabelCatalog.fieldPlaceholder(
            name: "font-size", title: "Font size", documentation: "Defaults to `13`.",
            defaultValue: "13", mineExample: false)
        XCTAssertEqual(placeholder, "13")
    }

    private func referenceCatalog() throws -> OptionCatalog {
        CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"))
    }
}
