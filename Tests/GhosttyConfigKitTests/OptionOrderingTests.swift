import XCTest
@testable import GhosttyConfigKit

final class OptionOrderingTests: XCTestCase {

    private func referenceCatalog() throws -> OptionCatalog {
        CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"))
    }

    func testCommonSortsAboveAdvancedWithinCategory() throws {
        let appearance = try referenceCatalog().options(in: "Appearance").map(\.name)
        let opacity = appearance.firstIndex(of: "background-opacity")!  // common, rank 1
        let alpha = appearance.firstIndex(of: "alpha-blending")!        // advanced
        XCTAssertLessThan(opacity, alpha)
    }

    func testCommonOrderFollowsCuratedRank() throws {
        let font = try referenceCatalog().options(in: "Font & Text").map(\.name)
        let family = font.firstIndex(of: "font-family")!
        let size = font.firstIndex(of: "font-size")!
        let feature = font.firstIndex(of: "font-feature")!
        XCTAssertLessThan(family, size)    // rank 1 < 2
        XCTAssertLessThan(size, feature)   // rank 2 < 3
        // A common option precedes an advanced one in the same category.
        let adjust = font.firstIndex(of: "adjust-cell-height")!
        XCTAssertLessThan(family, adjust)
    }

    func testAdvancedCategoryIsAlphabetical() throws {
        // The Advanced category holds only advanced-tier options, so order is by name.
        let advanced = try referenceCatalog().options(in: "Advanced").map(\.name)
        XCTAssertEqual(advanced, advanced.sorted())
    }

    func testComparatorIsAntisymmetricAndIdempotent() throws {
        let catalog = try referenceCatalog()
        for category in catalog.categories {
            let opts = catalog.options(in: category)
            let resorted = opts.sorted(by: OptionOrdering.compare)
            XCTAssertEqual(opts.map(\.name), resorted.map(\.name), "re-sort changed \(category)")
            for (a, b) in zip(opts, opts.dropFirst()) {
                XCTAssertFalse(OptionOrdering.compare(b, a) && OptionOrdering.compare(a, b),
                               "\(a.name) and \(b.name) compare equal both ways")
            }
        }
    }

    func testBrowserAndCatalogAgreeOnOrder() throws {
        let catalog = try referenceCatalog()
        let merged = ConfigReader().merge(
            model: ConfigModel(primary: ConfigFile.parse(text: "font-size = 16", path: "/tmp/config")),
            catalog: catalog
        )
        let browser = CatalogBrowser(merged: merged, catalog: catalog)
        XCTAssertEqual(
            catalog.options(in: "Font & Text").map(\.name),
            browser.options(in: "Font & Text").map(\.option.name)
        )
    }
}
