import XCTest
@testable import GhosttyConfigKit

final class CatalogParserTests: XCTestCase {

    private func realCatalog() throws -> OptionCatalog {
        let text = try Fixture.text("show-config-default-docs", "txt")
        return CatalogParser.parse(text, version: "1.3.1")
    }

    // MARK: - Option count + known options (R1)

    func testParsesRepresentativeOptionCount() throws {
        let catalog = try realCatalog()
        // Real 1.3.1 output has 200 distinct option names.
        XCTAssertEqual(catalog.options.count, 200)
        XCTAssertEqual(catalog.version, "1.3.1")
    }

    func testKnownOptionsArePresentWithDefaults() throws {
        let catalog = try realCatalog()
        XCTAssertNotNil(catalog.option(named: "font-family"))
        XCTAssertNotNil(catalog.option(named: "theme"))
        XCTAssertNotNil(catalog.option(named: "keybind"))

        let fontSize = catalog.option(named: "font-size")
        XCTAssertEqual(fontSize?.defaultValue, "13")
        XCTAssertEqual(fontSize?.valueType, .number)

        let opacity = catalog.option(named: "background-opacity")
        XCTAssertEqual(opacity?.defaultValue, "1")
        XCTAssertEqual(opacity?.valueType, .number)
    }

    // MARK: - Docs associate with the right option (R2)

    func testDocTextAssociatesWithCorrectOption() throws {
        let catalog = try realCatalog()
        let fontFamily = try XCTUnwrap(catalog.option(named: "font-family"))
        XCTAssertTrue(fontFamily.documentation.lowercased().contains("font famil"),
                      "font-family docs should describe font families")

        let cursorStyle = try XCTUnwrap(catalog.option(named: "cursor-style"))
        XCTAssertTrue(cursorStyle.documentation.lowercased().contains("valid values"))
    }

    func testDistinctKeysUnderOneDocBlockEachBecomeAnOption() throws {
        let catalog = try realCatalog()
        // font-family / -bold / -italic / -bold-italic share one doc block but
        // are four separate options.
        for name in ["font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic"] {
            XCTAssertNotNil(catalog.option(named: name), "expected \(name) to be its own option")
        }
    }

    // MARK: - Enum + type inference (R2)

    func testEnumValuesExtractedFromValidValuesSection() throws {
        let catalog = try realCatalog()
        let cursorStyle = try XCTUnwrap(catalog.option(named: "cursor-style"))
        XCTAssertEqual(cursorStyle.valueType, .enumeration)
        XCTAssertEqual(cursorStyle.enumValues, ["block", "bar", "underline", "block_hollow"])
        XCTAssertEqual(cursorStyle.defaultValue, "block")
    }

    // MARK: - Repeatable keys (R9 foundation)

    func testRepeatableKeysAreRepresentedAsSuch() throws {
        let catalog = try realCatalog()
        let keybind = try XCTUnwrap(catalog.option(named: "keybind"))
        XCTAssertTrue(keybind.isRepeatable)
        XCTAssertGreaterThan(keybind.defaultValues.count, 1, "keybind has many default binds")

        let palette = try XCTUnwrap(catalog.option(named: "palette"))
        XCTAssertTrue(palette.isRepeatable)
        XCTAssertGreaterThanOrEqual(palette.defaultValues.count, 16, "palette defaults cover 0–15")
        XCTAssertEqual(palette.defaultValues.first, "0=#1d1f21")
    }

    // MARK: - Categories drive the sidebar (R3)

    func testCategoriesAreDerivedAndOrdered() throws {
        let catalog = try realCatalog()
        XCTAssertEqual(catalog.option(named: "font-size")?.category, "Font")
        XCTAssertEqual(catalog.option(named: "keybind")?.category, "Keybindings")
        XCTAssertEqual(catalog.option(named: "theme")?.category, "Colors & Theme")
        // Known categories sort ahead of "General".
        let cats = catalog.categories
        XCTAssertEqual(cats.first, "Font")
        XCTAssertTrue(cats.contains("Keybindings"))
    }

    // MARK: - Tolerance (R1 resilience)

    func testGarbledLinesAreToleratedNotFatal() {
        let messy = """
        # A good option
        good-option = yes

        this is not a config line at all
        =leading equals with no key
        # Another
        another = 1=2=3

        @@@ totally bogus @@@
        """
        let catalog = CatalogParser.parse(messy)
        XCTAssertNotNil(catalog.option(named: "good-option"))
        XCTAssertEqual(catalog.option(named: "another")?.defaultValue, "1=2=3")
        // The bogus lines produced no spurious options.
        XCTAssertEqual(catalog.options.count, 2)
    }

    func testValueWithEmbeddedEqualsPreserved() {
        let catalog = CatalogParser.parse("keybind = super+,=open_config")
        XCTAssertEqual(catalog.option(named: "keybind")?.defaultValue, "super+,=open_config")
    }

    // MARK: - Cache keyed by version (R1)

    func testCacheReusesParsedCatalogForSameVersion() async throws {
        let loadCount = LoadCounter()
        let provider = CatalogProvider { _ in
            await loadCount.increment()
            return "font-size = 13"
        }
        _ = try await provider.catalog(forVersion: "1.3.1")
        _ = try await provider.catalog(forVersion: "1.3.1")
        let count = await loadCount.value
        XCTAssertEqual(count, 1, "same version should load + parse only once")
    }

    func testCacheInvalidatesOnVersionChange() async throws {
        let loadCount = LoadCounter()
        let provider = CatalogProvider { _ in
            await loadCount.increment()
            return "font-size = 13"
        }
        _ = try await provider.catalog(forVersion: "1.3.1")
        _ = try await provider.catalog(forVersion: "1.4.0")
        let count = await loadCount.value
        XCTAssertEqual(count, 2, "a new version should trigger a reload")
    }
}

/// Counts loader invocations across actor boundaries.
private actor LoadCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
