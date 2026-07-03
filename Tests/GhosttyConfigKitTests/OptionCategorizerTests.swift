import XCTest
@testable import GhosttyConfigKit

final class OptionCategorizerTests: XCTestCase {

    private func referenceCatalog() throws -> OptionCatalog {
        CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"))
    }

    // MARK: - Golden category pins (~25 headline options)

    func testGoldenCategoryPins() {
        let expected: [String: String] = [
            "background-opacity": "Appearance",
            "background": "Appearance",
            "foreground": "Appearance",
            "theme": "Appearance",
            "palette": "Appearance",
            "minimum-contrast": "Appearance",
            "font-family": "Font & Text",
            "font-size": "Font & Text",
            "font-feature": "Font & Text",
            "adjust-cell-height": "Font & Text",
            "window-decoration": "Window",
            "macos-titlebar-style": "Window",
            "window-padding-x": "Window",
            "unfocused-split-opacity": "Tabs & Splits",
            "split-divider-color": "Tabs & Splits",
            "cursor-style": "Cursor",
            "cursor-color": "Cursor",
            "mouse-scroll-multiplier": "Mouse & Scrolling",
            "scrollback-limit": "Mouse & Scrolling",
            "focus-follows-mouse": "Mouse & Scrolling",
            "keybind": OptionCategorizer.keybindingsCategory,
            "copy-on-select": "Clipboard",
            "clipboard-read": "Clipboard",
            "desktop-notifications": "Notifications & Bell",
            "bell-features": "Notifications & Bell",
            "notify-on-command-finish": "Notifications & Bell",
            "shell-integration": "Startup & Shell",
            "command": "Startup & Shell",
            "working-directory": "Startup & Shell",
            "macos-option-as-alt": "macOS",
            "term": "Advanced",
            "enquiry-response": "Advanced",
            "config-file": "Advanced",
        ]
        for (name, category) in expected {
            XCTAssertEqual(OptionCategorizer.category(for: name), category, "wrong category for \(name)")
        }
    }

    // MARK: - Golden tier/rank pins

    func testGoldenTierAndRankPins() {
        let tiers = OptionTierCatalog.bundled
        XCTAssertTrue(tiers.isCommon("font-family"))
        XCTAssertEqual(tiers.rank(for: "font-family"), 1)
        XCTAssertEqual(tiers.rank(for: "font-size"), 2)
        XCTAssertEqual(tiers.rank(for: "font-feature"), 3)
        XCTAssertTrue(tiers.isCommon("background-opacity"))
        // An internal is advanced with the sentinel rank.
        XCTAssertFalse(tiers.isCommon("enquiry-response"))
        XCTAssertEqual(tiers.rank(for: "enquiry-response"), Int.max)
    }

    // MARK: - No "General", everything resolves to a real category

    func testNoOptionLandsInGeneralAndAllResolveToKnownCategory() throws {
        let known = Set(OptionCategorizer.displayOrder)
        for option in try referenceCatalog().options {
            XCTAssertNotEqual(option.category, "General", "\(option.name) still lands in General")
            XCTAssertTrue(known.contains(option.category), "\(option.name) → unknown category \(option.category)")
        }
    }

    func testUnmappedOptionFallsBackToAdvanced() {
        XCTAssertEqual(OptionCategorizer.category(for: "some-brand-new-ghostty-option"), "Advanced")
    }

    func testSidebarCategoriesLeadWithAppearanceAndHaveNoGeneral() throws {
        let cats = try referenceCatalog().categories
        XCTAssertEqual(cats.first, "Appearance")
        XCTAssertFalse(cats.contains("General"))
        XCTAssertTrue(cats.contains("Advanced"))
        XCTAssertTrue(cats.contains(OptionCategorizer.keybindingsCategory))
    }

    // MARK: - Orphan-key guard (KTD1)

    func testEveryTierKeyResolvesInCatalog() throws {
        let names = Set(try referenceCatalog().options.map(\.name))
        let orphans = OptionTierCatalog.bundled.tieredOptionNames.subtracting(names)
        XCTAssertTrue(orphans.isEmpty, "option-tiers.json has keys absent from the catalog: \(orphans.sorted())")
    }
}
