import XCTest
@testable import GhosttyConfigKit

final class NumericSpecTests: XCTestCase {

    func testSpecLookupReturnsSeededRangeStepStyle() {
        let spec = NumericSpecCatalog.bundled.spec(for: "background-opacity")
        XCTAssertEqual(spec?.min, 0)
        XCTAssertEqual(spec?.max, 1)
        XCTAssertEqual(spec?.step, 0.05)
        XCTAssertEqual(spec?.style, .slider)
    }

    func testFontSizeSpecCarriesUnitAndRange() {
        let spec = NumericSpecCatalog.bundled.spec(for: "font-size")
        XCTAssertEqual(spec?.unit, "pt")
        XCTAssertEqual(spec?.min, 4)
        XCTAssertEqual(spec?.max, 72)
        XCTAssertEqual(spec?.style, .field)
    }

    func testByteLimitsUseSizeStyle() {
        XCTAssertEqual(NumericSpecCatalog.bundled.spec(for: "image-storage-limit")?.style, .size)
        XCTAssertEqual(NumericSpecCatalog.bundled.spec(for: "scrollback-limit")?.style, .size)
    }

    func testOptionsWithoutASpecReturnNil() {
        XCTAssertNil(NumericSpecCatalog.bundled.spec(for: "font-family"))
        XCTAssertNil(NumericSpecCatalog.bundled.spec(for: "some-unknown-xyz"))
    }

    func testCatalogOptionConvenienceExposesSpec() throws {
        let option = try referenceCatalog().option(named: "background-opacity")!
        XCTAssertEqual(option.numericSpec?.style, .slider)
    }

    func testEveryNumericSpecKeyResolvesInCatalog() throws {
        let names = Set(try referenceCatalog().options.map(\.name))
        let orphans = NumericSpecCatalog.bundled.specOptionNames.subtracting(names)
        XCTAssertTrue(orphans.isEmpty, "numeric-specs.json has keys absent from the catalog: \(orphans.sorted())")
    }

    private func referenceCatalog() throws -> OptionCatalog {
        CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"))
    }
}
