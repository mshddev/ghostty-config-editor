import XCTest
@testable import GhosttyConfigEditor
@testable import GhosttyConfigKit

final class PresentationPolicyTests: XCTestCase {
    func testExecutableTargetCanBeImportedWithoutLaunchingApplication() {
        XCTAssertGreaterThan(WindowMetrics.contentMaxWidth, 0)
    }

    // MARK: - Editor routing policy (U4, scenario 6 + R6 guard + AE5)

    // Scenario 6 + R6: no editable repeatable in the reference catalog falls through to an
    // info-only dead row, and none is mis-routed to a scalar inline control.
    func testEveryEditableRepeatableRoutesToARealEditor() throws {
        for option in try referenceCatalog().options
        where option.isRepeatable && option.presentation.editability == .editable {
            let route = OptionEditorRoute.resolve(for: option)
            XCTAssertNotEqual(route, .infoOnly, "editable repeatable fell through to info-only: \(option.name)")
            XCTAssertNotEqual(route, .inline, "repeatable mis-routed to a scalar editor: \(option.name)")
        }
    }

    // AE5: config-file and command-palette-entry classify to a working add/remove editor —
    // config-file's path list also offering a chooser.
    func testConfigFileAndCommandPaletteRouteToAddRemoveEditors() throws {
        let catalog = try referenceCatalog()
        XCTAssertEqual(OptionEditorRoute.resolve(for: try XCTUnwrap(catalog.option(named: "config-file"))), .pathList)
        XCTAssertEqual(OptionEditorRoute.resolve(for: try XCTUnwrap(catalog.option(named: "command-palette-entry"))), .repeatableList)
    }

    // Scenario 6: keybind, palette, fonts, and environment still route to their dedicated
    // surfaces rather than the generic fallback.
    func testDedicatedSurfacesStillWin() throws {
        let catalog = try referenceCatalog()
        XCTAssertEqual(OptionEditorRoute.resolve(for: try XCTUnwrap(catalog.option(named: "keybind"))), .keybindDeepLink)
        XCTAssertEqual(OptionEditorRoute.resolve(for: try XCTUnwrap(catalog.option(named: "palette"))), .palette)
        XCTAssertEqual(OptionEditorRoute.resolve(for: try XCTUnwrap(catalog.option(named: "font-family"))), .fontFamily)
        XCTAssertEqual(OptionEditorRoute.resolve(for: try XCTUnwrap(catalog.option(named: "font-feature"))), .fontFeature)
        XCTAssertEqual(OptionEditorRoute.resolve(for: try XCTUnwrap(catalog.option(named: "env"))), .repeatableList)
    }

    // The structured single-value editors route by editor kind (R7).
    func testStructuredSingleValueOptionsRouteToTheirEditors() throws {
        let catalog = try referenceCatalog()
        XCTAssertEqual(OptionEditorRoute.resolve(for: try XCTUnwrap(catalog.option(named: "mouse-scroll-multiplier"))), .scrollMultiplier)
        XCTAssertEqual(OptionEditorRoute.resolve(for: try XCTUnwrap(catalog.option(named: "bell-features"))), .bellFeatures)
        XCTAssertEqual(OptionEditorRoute.resolve(for: try XCTUnwrap(catalog.option(named: "working-directory"))), .pathChooser)
    }

    // Scenario 5 (app view): color-valued options route to the color editor even when their
    // inferred value type isn't `.color`.
    func testColorKindOptionsRouteToColorEditor() throws {
        let catalog = try referenceCatalog()
        for name in ["unfocused-split-fill", "selection-background", "selection-foreground"] {
            XCTAssertEqual(OptionEditorRoute.resolve(for: try XCTUnwrap(catalog.option(named: name))), .color,
                           "\(name) should route to the shared color editor")
        }
    }

    // Structural R6: across every editor kind, an editable repeatable never resolves to an
    // info-only dead row (or a scalar inline control) — independent of the current fixture, so
    // a future Ghostty repeatable can't reintroduce a silent row.
    func testResolverNeverInfoOnlyForAnyEditableRepeatableKind() {
        for kind in OptionEditorKind.allCases {
            let route = OptionEditorRoute.resolve(
                name: "probe-\(kind.rawValue)", editorKind: kind,
                editability: .editable, isRepeatable: true, valueType: .unknown
            )
            XCTAssertNotEqual(route, .infoOnly, "kind \(kind.rawValue) produced an info-only repeatable row")
            XCTAssertNotEqual(route, .inline, "kind \(kind.rawValue) mis-routed a repeatable to inline")
        }
    }

    // A read-only/excluded row is the only legitimate info-only route (R6 governs editable rows).
    func testReadOnlyOptionRoutesToInfoOnly() {
        let route = OptionEditorRoute.resolve(
            name: "read-only", editorKind: .automatic,
            editability: .readOnly, isRepeatable: false, valueType: .string
        )
        XCTAssertEqual(route, .infoOnly)
    }

    /// The reference catalog, read from the shared fixture in the kit test target via
    /// `#filePath` (SwiftPM scopes resource bundles per target, so the app-logic target reads
    /// the source-tree fixture directly rather than duplicating it).
    private func referenceCatalog() throws -> OptionCatalog {
        let fixture = URL(fileURLWithPath: #filePath)          // …/Tests/GhosttyConfigEditorTests/PresentationPolicyTests.swift
            .deletingLastPathComponent()                        // GhosttyConfigEditorTests
            .deletingLastPathComponent()                        // Tests
            .appendingPathComponent("GhosttyConfigKitTests/Fixtures/show-config-default-docs.txt")
        return CatalogParser.parse(try String(contentsOf: fixture, encoding: .utf8))
    }
}
