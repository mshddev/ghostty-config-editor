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

    // MARK: - B3 clamp / byte formatting / step inference

    func testClampMapsOutOfRangeToBoundaryAndLeavesInRangeAlone() {
        let opacity = NumericSpec(min: 0, max: 1, step: 0.05, style: .slider)
        XCTAssertEqual(opacity.clamp(-0.4), 0)      // below min → min
        XCTAssertEqual(opacity.clamp(1.7), 1)       // above max → max
        XCTAssertEqual(opacity.clamp(0.5), 0.5)     // in range → unchanged
    }

    func testClampWithOpenBoundLeavesThatSideFree() {
        // A size spec has no min/max — clamp must not invent bounds.
        let size = NumericSpec(style: .size)
        XCTAssertEqual(size.clamp(9_999_999), 9_999_999)
        XCTAssertEqual(size.clamp(-5), -5)
    }

    func testFormatBytesRendersDecimalUnits() {
        XCTAssertEqual(NumericSpec.formatBytes(320_000_000), "320 MB")
        XCTAssertEqual(NumericSpec.formatBytes(2_000_000_000), "2 GB")
        XCTAssertEqual(NumericSpec.formatBytes(1_500_000), "1.5 MB")
        XCTAssertEqual(NumericSpec.formatBytes(4_096), "4.1 KB")
        XCTAssertEqual(NumericSpec.formatBytes(512), "512 bytes")
        XCTAssertEqual(NumericSpec.formatBytes(0), "0 bytes")
    }

    func testFormatBytesUnitBoundaries() {
        XCTAssertEqual(NumericSpec.formatBytes(999), "999 bytes")        // just under 1 KB
        XCTAssertEqual(NumericSpec.formatBytes(1_000), "1 KB")          // exactly 1 KB
        XCTAssertEqual(NumericSpec.formatBytes(1_000_000), "1 MB")      // exactly 1 MB
        XCTAssertEqual(NumericSpec.formatBytes(1_000_000_000), "1 GB")  // exactly 1 GB
    }

    func testInferredStepFromDefault() {
        XCTAssertEqual(NumericSpec.inferredStep(forDefault: "0.5"), 0.1)   // fractional → fine
        XCTAssertEqual(NumericSpec.inferredStep(forDefault: "16"), 1)      // integer → whole
        XCTAssertEqual(NumericSpec.inferredStep(forDefault: ""), 1)        // unparseable → whole
        XCTAssertEqual(NumericSpec.inferredStep(forDefault: "block"), 1)   // non-numeric → whole
    }

    private func referenceCatalog() throws -> OptionCatalog {
        CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"))
    }
}
