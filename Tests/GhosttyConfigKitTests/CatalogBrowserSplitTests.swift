import XCTest
@testable import GhosttyConfigKit

/// B1 (U7): the Common/Advanced split that drives the option list's sections.
final class CatalogBrowserSplitTests: XCTestCase {

    private func catalog() throws -> OptionCatalog {
        CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"))
    }

    private func browser(config: String) throws -> CatalogBrowser {
        let catalog = try catalog()
        let merged = ConfigReader().merge(
            model: ConfigModel(primary: ConfigFile.parse(text: config, path: "/tmp/config")),
            catalog: catalog
        )
        return CatalogBrowser(merged: merged, catalog: catalog)
    }

    func testCommonOptionsLeadWithCuratedOrder() throws {
        let common = try browser(config: "font-size = 16").commonOptions(in: "Font & Text").map(\.option.name)
        XCTAssertEqual(Array(common.prefix(2)), ["font-family", "font-size"])
        // adjust-* is advanced — absent from Common while at its default.
        XCTAssertFalse(common.contains("adjust-cell-height"))
    }

    func testCommonAndAdvancedPartitionTheCategory() throws {
        let b = try browser(config: "font-size = 16")
        let all = Set(b.options(in: "Font & Text").map(\.option.name))
        let common = Set(b.commonOptions(in: "Font & Text").map(\.option.name))
        let advanced = Set(b.advancedOptions(in: "Font & Text").map(\.option.name))
        XCTAssertEqual(common.union(advanced), all, "split must cover every option")
        XCTAssertTrue(common.isDisjoint(with: advanced), "an option can't be in both sections")
        XCTAssertTrue(advanced.contains("adjust-cell-height"))
    }

    func testCustomizedAdvancedOptionPromotesToCommon() throws {
        // An advanced option changed from its default surfaces in Common so a changed
        // setting is never hidden behind the collapsed Advanced disclosure (R2).
        let b = try browser(config: "adjust-cell-height = 15%")
        XCTAssertTrue(b.commonOptions(in: "Font & Text").contains { $0.option.name == "adjust-cell-height" })
        XCTAssertFalse(b.advancedOptions(in: "Font & Text").contains { $0.option.name == "adjust-cell-height" })
    }

    func testAdvancedSetToItsDefaultStaysAdvanced() throws {
        // Promotion keys on setNonDefault, not merely isSet — writing an advanced
        // option to its own default is not a customization, so it stays advanced.
        let def = try catalog().option(named: "adjust-cell-height")!.defaultValue
        let b = try browser(config: "adjust-cell-height = \(def)")
        XCTAssertFalse(b.commonOptions(in: "Font & Text").contains { $0.option.name == "adjust-cell-height" })
        XCTAssertTrue(b.advancedOptions(in: "Font & Text").contains { $0.option.name == "adjust-cell-height" })
    }

    func testSearchIgnoresTheSplit() throws {
        // The split is a browse-only affordance; search returns ranked hits across
        // both tiers.
        let hits = try browser(config: "font-size = 16").searchResults("adjust").map(\.option.name)
        XCTAssertTrue(hits.contains("adjust-cell-height"))
    }
}
