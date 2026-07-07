import XCTest
@testable import GhosttyConfigEditor
@testable import GhosttyConfigKit

/// AE6 / R11 / KTD5: the per-surface content-width policy. Pure width math — no SwiftUI
/// layout, no `NSApplication` — so "forms stay readable while Themes and Keyboard Shortcuts
/// use available width" is directly assertable (KTD7). Replaces the single 640-cap that
/// stranded every surface in a maximized window.
final class ContentWidthPolicyTests: XCTestCase {

    // MARK: - Form measure stays bounded (AE6 scenario 1)

    // A grouped form keeps a readable measure at the minimum, default, AND maximized window
    // widths — it never expands to fill a maximized window.
    func testFormWidthStaysBoundedAtEveryWindowSize() {
        for windowWidth in [WindowMetrics.minWidth, WindowMetrics.defaultWidth, WindowMetrics.maxWidth] {
            let width = ContentWidthPolicy.resolvedContentWidth(for: .form, windowWidth: windowWidth)
            XCTAssertLessThanOrEqual(width, ContentWidthPolicy.formMaxWidth,
                                     "a form must stay within its readable measure at window \(windowWidth)")
        }
    }

    // At a maximized window the form pins to exactly its readable measure — not stranded
    // tiny, not sprawling edge to edge.
    func testFormWidthPinsToReadableMeasureWhenMaximized() {
        let width = ContentWidthPolicy.resolvedContentWidth(for: .form, windowWidth: WindowMetrics.maxWidth)
        XCTAssertEqual(width, ContentWidthPolicy.formMaxWidth)
    }

    // MARK: - Themes / Keyboard Shortcuts expand (AE6 scenario 1)

    // At a maximized window Themes and Keyboard Shortcuts resolve WIDER than a grouped form
    // does — the room the grid uses for more columns and chords use for space.
    func testThemesAndShortcutsResolveWiderThanFormWhenMaximized() {
        let window = WindowMetrics.maxWidth
        let form = ContentWidthPolicy.resolvedContentWidth(for: .form, windowWidth: window)
        let themes = ContentWidthPolicy.resolvedContentWidth(for: .themes, windowWidth: window)
        let shortcuts = ContentWidthPolicy.resolvedContentWidth(for: .keyboardShortcuts, windowWidth: window)
        XCTAssertGreaterThan(themes, form, "Themes must gain width over a form at a maximized window")
        XCTAssertGreaterThan(shortcuts, form, "Keyboard Shortcuts must gain width over a form at a maximized window")
    }

    // No surface ever resolves narrower than a form at the same window size — a wide surface
    // only ever gains width, so a maximized window can't strand a tiny panel (AE6).
    func testWideSurfacesAreNeverNarrowerThanAForm() {
        for windowWidth in [WindowMetrics.minWidth, WindowMetrics.defaultWidth, WindowMetrics.maxWidth] {
            let form = ContentWidthPolicy.resolvedContentWidth(for: .form, windowWidth: windowWidth)
            XCTAssertGreaterThanOrEqual(
                ContentWidthPolicy.resolvedContentWidth(for: .themes, windowWidth: windowWidth), form)
            XCTAssertGreaterThanOrEqual(
                ContentWidthPolicy.resolvedContentWidth(for: .keyboardShortcuts, windowWidth: windowWidth), form)
        }
    }

    // The wide bound is still a bound — even an absurdly wide window keeps Themes within the
    // bounded canvas rather than sprawling edge to edge (KTD5 "bounded wide canvas").
    func testWideCanvasStaysBounded() {
        let width = ContentWidthPolicy.resolvedContentWidth(for: .themes, windowWidth: 4000)
        XCTAssertEqual(width, ContentWidthPolicy.wideMaxWidth)
    }

    // MARK: - Surface identity derivation (keyed off the model's navigation state)

    func testSurfaceResolvesFromSelection() {
        XCTAssertEqual(ContentSurface.resolve(selection: .themes, statusDestination: .hub, isFinding: false), .themes)
        XCTAssertEqual(ContentSurface.resolve(selection: .category(OptionCategorizer.keybindingsCategory),
                                              statusDestination: .hub, isFinding: false), .keyboardShortcuts)
        XCTAssertEqual(ContentSurface.resolve(selection: .category("Appearance"),
                                              statusDestination: .hub, isFinding: false), .form)
        XCTAssertEqual(ContentSurface.resolve(selection: .recommended, statusDestination: .hub, isFinding: false), .form)
        XCTAssertEqual(ContentSurface.resolve(selection: .status, statusDestination: .hub, isFinding: false), .form)
        XCTAssertEqual(ContentSurface.resolve(selection: .status, statusDestination: .customized, isFinding: false), .form)
    }

    // Global Find overlays every surface with a results list, so it reads as a form even over
    // Themes (its wide grid isn't what's showing).
    func testGlobalFindResolvesToFormEvenOverThemes() {
        XCTAssertEqual(ContentSurface.resolve(selection: .themes, statusDestination: .hub, isFinding: true), .form)
    }
}
