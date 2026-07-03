import XCTest
@testable import GhosttyConfigKit

final class RecommendedSettingsTests: XCTestCase {

    // MARK: - Loads + shape (F1)

    func testBundledRecommendedListLoadsWithSections() {
        let recommended = RecommendedSettings.bundled
        XCTAssertFalse(recommended.sections.isEmpty, "the bundled recommended list should load")
        XCTAssertFalse(recommended.optionNames.isEmpty, "sections should carry recommended options")
    }

    func testGroupsIntoTheDeclaredSections() {
        let titles = RecommendedSettings.bundled.sections.map(\.title)
        XCTAssertEqual(titles, ["Appearance", "Behavior"],
                       "the recommended surface groups into Appearance then Behavior")
        // Theme is the first thing a newcomer sets, so it leads the Appearance group.
        XCTAssertEqual(RecommendedSettings.bundled.sections.first?.options.first, "theme")
    }

    func testDecodesFromExplicitJSON() throws {
        let json = """
        {"sections":[{"title":"Group","options":["a","b"]}]}
        """
        let settings = try RecommendedSettings.decode(Data(json.utf8))
        XCTAssertEqual(settings.sections, [.init(title: "Group", options: ["a", "b"])])
        XCTAssertEqual(settings.optionNames, ["a", "b"])
    }

    // MARK: - Orphan-key guard (KTD1)

    func testEveryRecommendedKeyResolvesInReferenceCatalog() throws {
        // KTD1: a recommended key that no longer exists in the catalog (renamed/removed
        // on a Ghostty upgrade) must fail loudly rather than render an empty row.
        let catalog = CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"))
        let names = Set(catalog.options.map(\.name))
        let orphans = RecommendedSettings.bundled.recommendedOptionNames.subtracting(names)
        XCTAssertTrue(orphans.isEmpty,
                      "recommended-settings.json has keys absent from the catalog: \(orphans.sorted())")
    }
}
