import XCTest
@testable import GhosttyConfigEditor
@testable import GhosttyConfigKit

/// R12 / AE8: the flagship theme-row action policy and the browsing-bucket dedup. Pure — no
/// SwiftUI rendering — so "Apply, Favorite, and Theme Options each appear exactly once with
/// distinct labels" and the current/favorites dedup are directly assertable (KTD7). The
/// policy is the single source both the list row and the grid card read, so neither can drift
/// into a duplicate or "mystery" control.
final class ThemeActionPolicyTests: XCTestCase {

    // MARK: - One-of-each + distinct labels (AE8 scenario 3)

    // A theme's action set has exactly one Apply, one Favorite, one Theme Options — and no
    // more (no duplicate/mystery control).
    func testExactlyOneOfEachAction() {
        let actions = ThemeActionPolicy.actions(themeName: "Solarized", isFavorite: false,
                                                applyIdentityLabel: "Solarized, dark")
        let kinds = actions.all.map(\.kind)
        XCTAssertEqual(kinds.count, 3)
        for kind in ThemeActionPolicy.Kind.allCases {
            XCTAssertEqual(kinds.filter { $0 == kind }.count, 1, "expected exactly one \(kind)")
        }
    }

    // Each action carries a distinct accessibility label, shared by list and grid (the policy
    // is the single source both views read).
    func testActionsHaveDistinctLabels() {
        let actions = ThemeActionPolicy.actions(themeName: "Nord", isFavorite: true,
                                                applyIdentityLabel: "Nord, dark, current theme")
        let labels = actions.all.map(\.accessibilityLabel)
        XCTAssertEqual(Set(labels).count, labels.count, "labels must be distinct: \(labels)")
    }

    // Apply announces the theme identity and carries its verb as a hint; Favorite and Options
    // name their action directly. So Apply / Favorite / Options are three legible, separate
    // accessibility elements — not one merged blob.
    func testApplyCarriesIdentityAndHint() {
        let actions = ThemeActionPolicy.actions(themeName: "Nord", isFavorite: false,
                                                applyIdentityLabel: "Nord, dark")
        XCTAssertEqual(actions.apply.accessibilityLabel, "Nord, dark")
        XCTAssertEqual(actions.apply.accessibilityHint, "Apply this theme")
        XCTAssertNil(actions.favorite.accessibilityHint)
        XCTAssertNil(actions.options.accessibilityHint)
    }

    // The favorite action reflects state in both label and glyph, so starred vs unstarred is
    // never conveyed by color alone (scenario 6).
    func testFavoriteActionReflectsState() {
        let starred = ThemeActionPolicy.actions(themeName: "Nord", isFavorite: true, applyIdentityLabel: "Nord").favorite
        let unstarred = ThemeActionPolicy.actions(themeName: "Nord", isFavorite: false, applyIdentityLabel: "Nord").favorite
        XCTAssertEqual(starred.systemImage, "star.fill")
        XCTAssertEqual(unstarred.systemImage, "star")
        XCTAssertNotEqual(starred.accessibilityLabel, unstarred.accessibilityLabel)
    }

    // MARK: - Section dedup across favorite/filter/current transitions (AE8 scenario 4)

    private func ref(_ name: String) -> ThemeRef { ThemeRef(name: name, source: "resources", path: "/\(name)") }

    // The current theme now STAYS in the browse list (highlighted in place, and also shown in
    // the pinned "Current theme" section) rather than being pulled out of it — but a
    // current+favorite theme still never doubles into the Favorites band (IA-7), and a plain
    // favorite is still deduped out of browse into that band.
    func testCurrentThemeStaysInBrowseButFavoritesAreDeduped() {
        let filtered = [ref("Nord"), ref("Solarized"), ref("Dracula")]
        let buckets = ThemeSectionPolicy.buckets(
            filtered: filtered,
            currentNames: ["Nord"],
            isFavorite: { $0 == "Nord" || $0 == "Solarized" },   // Nord is current AND favorite
            filter: .all)
        XCTAssertTrue(buckets.browse.contains { $0.name == "Nord" }, "current theme stays in the browse list (highlighted, not hidden)")
        XCTAssertFalse(buckets.favorites.contains { $0.name == "Nord" }, "a current+favorite theme must not double into Favorites")
        XCTAssertTrue(buckets.favorites.contains { $0.name == "Solarized" })
        XCTAssertTrue(buckets.browse.contains { $0.name == "Dracula" })
        XCTAssertFalse(buckets.browse.contains { $0.name == "Solarized" }, "a favorite must not also be in browse")
    }

    // With no favorites, the browse list is the full filtered set — the current theme is not
    // subtracted from it (2026-07-09: applying a theme must not make it vanish from the list).
    func testCurrentThemeStaysInBrowseList() {
        let filtered = [ref("Nord"), ref("Solarized"), ref("Dracula")]
        let buckets = ThemeSectionPolicy.buckets(
            filtered: filtered, currentNames: ["Solarized"],
            isFavorite: { _ in false }, filter: .all)
        XCTAssertEqual(buckets.browse.map(\.name), ["Nord", "Solarized", "Dracula"],
                       "the current theme stays in the main list (it also appears pinned on top)")
    }

    // Under a non-`all` filter the Favorites band is suppressed (the filter already scopes the
    // list) — favorites then live in the main browse list, and the current theme stays in it too.
    func testFavoritesBandSuppressedUnderFilter() {
        let filtered = [ref("Nord"), ref("Solarized")]
        let buckets = ThemeSectionPolicy.buckets(
            filtered: filtered,
            currentNames: ["Nord"],
            isFavorite: { _ in true },
            filter: .favorites)
        XCTAssertTrue(buckets.favorites.isEmpty, "no separate Favorites band under a filter")
        XCTAssertEqual(buckets.browse.map(\.name), ["Nord", "Solarized"], "current stays in the filtered list (highlighted), not pinned out")
    }

    // Toggling favorite on/off moves a theme between the Favorites band and browse without ever
    // placing it in both (favorite transition preserves dedup).
    func testFavoriteToggleMovesBetweenBandsWithoutDuplication() {
        let filtered = [ref("Nord"), ref("Solarized")]
        let starred = ThemeSectionPolicy.buckets(filtered: filtered, currentNames: [],
                                                 isFavorite: { $0 == "Nord" }, filter: .all)
        XCTAssertEqual(starred.favorites.map(\.name), ["Nord"])
        XCTAssertEqual(starred.browse.map(\.name), ["Solarized"])

        let unstarred = ThemeSectionPolicy.buckets(filtered: filtered, currentNames: [],
                                                   isFavorite: { _ in false }, filter: .all)
        XCTAssertTrue(unstarred.favorites.isEmpty)
        XCTAssertEqual(unstarred.browse.map(\.name), ["Nord", "Solarized"])
    }
}
