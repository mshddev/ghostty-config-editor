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

    func testDiscoveryNeverSurfacesLinuxOnlyOptions() {
        // The "Not Using Yet" surface and search must never recommend an option
        // that does nothing on macOS (R1, R6, macOS-scoped catalog).
        let b = browser(config: "font-size = 16")
        let unusedNames = Set(b.unusedOptions.map(\.option.name))
        for name in ["gtk-titlebar", "app-notifications", "window-subtitle"] {
            XCTAssertFalse(unusedNames.contains(name), "\(name) must not appear in discovery")
        }
        XCTAssertTrue(b.searchResults("titlebar").allSatisfy { $0.option.name != "gtk-titlebar" })
        XCTAssertFalse(b.categories.contains("Linux / GTK"))
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
        XCTAssertEqual(cats.first, "Appearance")
        XCTAssertTrue(cats.contains(OptionCategorizer.keybindingsCategory))
    }

    // MARK: - Expanded intent coverage (A6, IA-9, ONBOARD-4)

    func testExpandedIntentPhrasesResolveToIntendedOptions() {
        let cases: [(phrase: String, expected: String)] = [
            ("opacity", "background-opacity"),
            ("startup command", "command"),
            ("bell sound", "bell-features"),
            ("tab position", "window-new-tab-position"),
            ("follow system dark mode", "theme"),
            ("notify when done", "notify-on-command-finish"),
            ("unfocused dim", "unfocused-split-opacity"),
            ("stop cursor blinking", "cursor-style-blink"),
        ]
        for (phrase, expected) in cases {
            let names = browser().searchResults(phrase).map(\.option.name)
            XCTAssertTrue(names.contains(expected), "intent '\(phrase)' should surface \(expected)")
        }
    }

    func testExistingIntentEntriesStillResolve() {
        // Guard against regressions in the entries that predate the A6 expansion.
        XCTAssertTrue(browser().searchResults("hide title bar").map(\.option.name).contains("macos-titlebar-style"))
        XCTAssertTrue(browser().searchResults("font size").map(\.option.name).contains("font-size"))
    }

    // MARK: - Global Find provenance (D2 / U20)

    func testSearchHitsPreserveMatchKindAndResolveOption() {
        // A name match resolves to the merged option and carries `.name` provenance.
        let pairs = browser().searchHits("background-opacity")
        let first = pairs.first
        XCTAssertEqual(first?.option.option.name, "background-opacity")
        XCTAssertEqual(first?.hit.matchKind, .name)
        // Every returned hit resolves to a real merged option (no dangling pairs).
        XCTAssertEqual(pairs.map(\.hit.optionName), pairs.map(\.option.option.name))
    }

    func testSearchHitsCarryCategoryForResultPills() {
        // The Find surface renders a per-row category pill from the resolved option.
        let pairs = browser().searchHits("background-opacity")
        let opacity = pairs.first { $0.option.option.name == "background-opacity" }
        XCTAssertEqual(opacity?.option.option.category, OptionCategorizer.appearanceCategory)
    }

    func testIntentHitCarriesMatchedPhraseForBadge() {
        // An intent match surfaces the phrase that matched, for the "matches: …" badge.
        let pairs = browser().searchHits("transparent background")
        let opacity = pairs.first { $0.option.option.name == "background-opacity" }
        XCTAssertEqual(opacity?.hit.matchKind, .intent)
        XCTAssertNotNil(opacity?.hit.intentPhrase, "intent hits carry the matched phrase")
        // The phrase is the curated one that overlaps the query, not the raw query.
        let phrase = opacity?.hit.intentPhrase?.lowercased() ?? ""
        XCTAssertTrue(phrase.contains("transparent") || phrase.contains("opacity"),
                      "phrase '\(phrase)' should be the matched intent phrase")
    }

    func testNameAndDocHitsHaveNoIntentPhrase() {
        // Only intent hits carry a phrase; a plain name match leaves it nil.
        let hit = browser().search.search("background-opacity").first { $0.optionName == "background-opacity" }
        XCTAssertEqual(hit?.matchKind, .name)
        XCTAssertNil(hit?.intentPhrase)
    }

    func testMatchesForReturnsSameOptionsAsOptionsMatching() {
        // options(matching:) now delegates to matches(for:); guard they stay in sync.
        for q in ["hide title bar", "opacity", "bell sound", "emoji"] {
            XCTAssertEqual(IntentMap.bundled.options(matching: q),
                           IntentMap.bundled.matches(for: q).map(\.option),
                           "options(matching:) and matches(for:) diverged for '\(q)'")
        }
    }

    func testEmptyQueryReturnsNoSearchHits() {
        XCTAssertTrue(browser().searchHits("   ").isEmpty)
    }

    func testEveryIntentMapOptionExistsInCatalog() {
        // KTD1-style guard: no phrase may map to an option absent from the catalog.
        let names = Set(catalog.options.map(\.name))
        for entry in IntentMap.bundled.entries {
            for option in entry.options {
                XCTAssertTrue(names.contains(option),
                              "intent-map.json references '\(option)', not present in the catalog")
            }
        }
    }
}
