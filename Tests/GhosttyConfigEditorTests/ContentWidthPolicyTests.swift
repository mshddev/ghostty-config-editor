import XCTest
@testable import GhosttyConfigEditor
@testable import GhosttyConfigKit

/// AE6 / R11 / KTD5: the per-surface content-width policy. Pure width caps — no SwiftUI
/// layout, no `NSApplication` — so "forms stay readable while Themes and Keyboard Shortcuts
/// use available width" is directly assertable (KTD7). `maxContentWidth(for:)` is the exact
/// value the live layout feeds into `.frame(maxWidth:)` (`SurfaceWidthColumn`), so these
/// exercise the production cap rather than a parallel re-derivation. Replaces the single
/// 640-cap that stranded every surface in a maximized window.
final class ContentWidthPolicyTests: XCTestCase {

    // MARK: - Form measure stays bounded (AE6 scenario 1)

    // A grouped form caps at its readable measure. `.frame(maxWidth:)` then keeps content
    // within this at every window size — never sprawling edge to edge in a maximized window.
    func testFormCapsAtReadableMeasure() {
        XCTAssertEqual(ContentWidthPolicy.maxContentWidth(for: .form), ContentWidthPolicy.formMaxWidth)
    }

    // MARK: - Themes / Keyboard Shortcuts expand (AE6 scenario 1)

    // Themes and Keyboard Shortcuts cap WIDER than a grouped form — the room the grid uses for
    // more columns and chords use for space.
    func testThemesAndShortcutsCapWiderThanForm() {
        let form = ContentWidthPolicy.maxContentWidth(for: .form)
        XCTAssertGreaterThan(ContentWidthPolicy.maxContentWidth(for: .themes), form,
                             "Themes must cap wider than a form")
        XCTAssertGreaterThan(ContentWidthPolicy.maxContentWidth(for: .keyboardShortcuts), form,
                             "Keyboard Shortcuts must cap wider than a form")
    }

    // No surface ever caps narrower than a form — a wide surface only ever gains width, so a
    // maximized window can't strand a tiny panel (AE6).
    func testWideSurfacesAreNeverNarrowerThanAForm() {
        let form = ContentWidthPolicy.maxContentWidth(for: .form)
        XCTAssertGreaterThanOrEqual(ContentWidthPolicy.maxContentWidth(for: .themes), form)
        XCTAssertGreaterThanOrEqual(ContentWidthPolicy.maxContentWidth(for: .keyboardShortcuts), form)
    }

    // The wide bound is still a bound (KTD5 "bounded wide canvas"): Themes and Keyboard
    // Shortcuts cap at a finite width that stays inside the window's own max, so even a
    // maximized window keeps a purposeful density rather than sprawling edge to edge.
    func testWideCanvasStaysBounded() {
        XCTAssertEqual(ContentWidthPolicy.maxContentWidth(for: .themes), ContentWidthPolicy.wideMaxWidth)
        XCTAssertEqual(ContentWidthPolicy.maxContentWidth(for: .keyboardShortcuts), ContentWidthPolicy.wideMaxWidth)
        XCTAssertLessThan(ContentWidthPolicy.wideMaxWidth, WindowMetrics.maxWidth)
    }

    // MARK: - Surface identity derivation (keyed off the model's navigation state)

    func testSurfaceResolvesFromSelection() {
        XCTAssertEqual(ContentSurface.resolve(selection: .themes, isFinding: false), .themes)
        XCTAssertEqual(ContentSurface.resolve(selection: .category(OptionCategorizer.keybindingsCategory),
                                              isFinding: false), .keyboardShortcuts)
        XCTAssertEqual(ContentSurface.resolve(selection: .category("Appearance"), isFinding: false), .form)
        XCTAssertEqual(ContentSurface.resolve(selection: .recommended, isFinding: false), .form)
        // The Status hub and its Problems drill-down both read as a form (the drill-down never
        // widens the column), so surface identity doesn't depend on the destination.
        XCTAssertEqual(ContentSurface.resolve(selection: .status, isFinding: false), .form)
    }

    // Global Find overlays every surface with a results list, so it reads as a form even over
    // Themes (its wide grid isn't what's showing).
    func testGlobalFindResolvesToFormEvenOverThemes() {
        XCTAssertEqual(ContentSurface.resolve(selection: .themes, isFinding: true), .form)
    }
}
