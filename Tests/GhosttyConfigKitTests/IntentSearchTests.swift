import XCTest
@testable import GhosttyConfigKit

final class IntentSearchTests: XCTestCase {

    private var catalog: OptionCatalog!
    private let reader = ConfigReader()

    override func setUpWithError() throws {
        catalog = CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"), version: "1.3.1")
    }

    private func browser(config: String = "font-size = 16") -> CatalogBrowser {
        let merged = reader.merge(
            model: ConfigModel(primary: ConfigFile.parse(text: config, path: "/tmp/config")),
            catalog: catalog
        )
        return CatalogBrowser(merged: merged, catalog: catalog)
    }

    // MARK: - Bundled map loads

    func testBundledIntentMapIsNonEmpty() {
        XCTAssertFalse(IntentMap.bundled.entries.isEmpty, "intent-map.json should be bundled and decode")
    }

    // MARK: - Name search (R3)

    func testNameSearchFiltersToMatchingOption() {
        let results = browser().searchResults("background-opacity")
        XCTAssertEqual(results.first?.option.name, "background-opacity")
    }

    func testNamePrefixOutranksSubstring() {
        // "font-size" is a prefix of font-size and a substring of nothing else
        // that should outrank it.
        let results = browser().searchResults("font-size")
        XCTAssertEqual(results.first?.option.name, "font-size")
    }

    // MARK: - Intent search (R4)

    func testIntentQueryMapsToExpectedOptions() {
        let results = browser().searchResults("hide title bar")
        let names = results.map(\.option.name)
        XCTAssertTrue(names.contains("macos-titlebar-style"),
                      "intent 'hide title bar' should surface macos-titlebar-style")
    }

    func testTransparentBackgroundSurfacesOpacityViaIntent() {
        let hits = browser().search.search("transparent background")
        let opacity = hits.first { $0.optionName == "background-opacity" }
        XCTAssertNotNil(opacity)
        XCTAssertEqual(opacity?.matchKind, .intent)
        // Intent ranks at the top.
        XCTAssertEqual(hits.first?.matchKind, .intent)
    }

    // MARK: - Full-text fallback (R4)

    func testNoIntentMappingFallsBackToFullText() {
        // "emoji" has no intent entry and is in no option *name*, but appears in
        // font-family's documentation.
        XCTAssertTrue(IntentMap.bundled.options(matching: "emoji").isEmpty)
        let hits = browser().search.search("emoji")
        let fontFamily = hits.first { $0.optionName == "font-family" }
        XCTAssertNotNil(fontFamily, "should fall back to documentation full-text")
        XCTAssertEqual(fontFamily?.matchKind, .documentation)
    }

    func testEmptyQueryReturnsNoResults() {
        XCTAssertTrue(browser().searchResults("   ").isEmpty)
    }

    // MARK: - Discovery surface (R6)

    func testUnusedSurfaceListsOnlyUnsetOptions() {
        let b = browser(config: "font-size = 16")
        let unused = b.unusedOptions
        XCTAssertTrue(unused.allSatisfy { !$0.isSet })
        XCTAssertTrue(unused.contains { $0.option.name == "cursor-style" })
        XCTAssertFalse(unused.contains { $0.option.name == "font-size" })
    }

    // MARK: - Copy snippet (read-only action)

    func testSnippetForSetScalarIsValidKeyValueLine() {
        let b = browser(config: "font-size = 16")
        let option = b.merged.option(named: "font-size")!
        let snippet = b.snippet(for: option)
        XCTAssertEqual(snippet, "font-size = 16")
        guard case .setting(let key, let value) = ConfigLine.classify(snippet) else {
            return XCTFail("snippet should classify as a setting line")
        }
        XCTAssertEqual(key, "font-size")
        XCTAssertEqual(value, "16")
    }

    func testSnippetForUnsetOptionUsesDefaultAndStaysValid() {
        let b = browser(config: "font-size = 16")
        let cursorStyle = b.merged.option(named: "cursor-style")!
        XCTAssertEqual(b.snippet(for: cursorStyle), "cursor-style = block")
    }

    func testSnippetForRepeatableEmitsOneLinePerValue() {
        let b = browser(config: "keybind = a=b\nkeybind = c=d")
        let keybind = b.merged.option(named: "keybind")!
        XCTAssertEqual(b.snippet(for: keybind), "keybind = a=b\nkeybind = c=d")
    }

    // MARK: - Categories drive the sidebar (R3)

    func testCategoriesIncludeKnownGroups() {
        let cats = browser().categories
        XCTAssertEqual(cats.first, "Font")
        XCTAssertTrue(cats.contains("Keybindings"))
    }
}
