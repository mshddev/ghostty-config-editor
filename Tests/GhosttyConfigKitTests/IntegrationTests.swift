import XCTest
@testable import GhosttyConfigKit

/// End-to-end checks against the real installed Ghostty. Skipped when the binary
/// isn't present so the suite stays green in a bare CI environment.
final class IntegrationTests: XCTestCase {

    private func requireGhostty() throws -> GhosttyCLI {
        guard let path = BinaryLocator.locateForTests() else {
            throw XCTSkip("Ghostty not installed")
        }
        return GhosttyCLI(binaryPath: path)
    }

    func testLiveCatalogParsesManyOptions() async throws {
        let cli = try requireGhostty()
        let result = try await cli.run(["+show-config", "--default", "--docs"])
        XCTAssertTrue(result.succeeded)
        let catalog = CatalogParser.parse(result.stdoutString)
        XCTAssertGreaterThan(catalog.options.count, 160, "live macOS-scoped catalog should list ~173 options")
        XCTAssertNotNil(catalog.option(named: "background-opacity"))
        XCTAssertNotNil(catalog.option(named: "keybind"))
    }

    func testLiveExplorerPipelineSurfacesOptionViaIntent() async throws {
        let cli = try requireGhostty()
        let version = try await cli.version()

        // Catalog (U2) from the live binary.
        let provider = CatalogProvider { _ in
            try await cli.run(["+show-config", "--default", "--docs"]).stdoutString
        }
        let catalog = try await provider.catalog(forVersion: version)

        // Config read + merge (U3). Use the real config if present, else empty.
        let reader = ConfigReader()
        let merged: MergedConfig
        if let primary = ConfigReader.locatePrimaryConfig(in: ConfigReader.configDirectory()) {
            let model = try reader.readModel(primaryPath: primary.path)
            merged = reader.merge(model: model, catalog: catalog)
        } else {
            merged = reader.merge(model: ConfigModel(primary: ConfigFile.parse(text: "", path: "")), catalog: catalog)
        }

        // Browser + intent search (U4): "transparent background" → background-opacity.
        let browser = CatalogBrowser(merged: merged, catalog: catalog)
        let results = browser.searchResults("transparent background")
        XCTAssertTrue(results.contains { $0.option.name == "background-opacity" },
                      "intent search should surface background-opacity end-to-end")

        let opacity = try XCTUnwrap(browser.merged.option(named: "background-opacity"))
        XCTAssertFalse(opacity.option.documentation.isEmpty, "detail pane needs docs")
        XCTAssertEqual(opacity.option.defaultValue, "1")
    }

    func testLiveValidateConfigSucceedsOnUserConfig() async throws {
        let cli = try requireGhostty()
        // The user's real config should validate clean (matches U5 verification).
        let result = try await cli.run(["+validate-config"])
        XCTAssertEqual(result.exitCode, 0, "the current config should validate clean: \(result.stderrString)")
    }

    func testLiveKeybindReferenceListsDefaultsAndActions() async throws {
        let cli = try requireGhostty()
        let environment = GhosttyEnvironment(cli: cli, version: try await cli.version())
        let provider = KeybindReferenceProvider.live(environment)

        // U1 verification: a non-empty defaults list and ~85 actions from the live
        // binary, parsed through the real provider path (not just the fixture).
        let actions = try await provider.actions()
        XCTAssertGreaterThan(actions.count, 50, "live +list-actions should list many actions")
        XCTAssertTrue(actions.contains(KeybindAction(name: "new_tab")))

        let defaults = try await provider.defaults()
        XCTAssertGreaterThan(defaults.count, 50, "live +list-keybinds --default should list many binds")
        // The `=`-key default is the canary that the action-set-aware split works
        // end-to-end against real output.
        XCTAssertTrue(defaults.contains { $0.canonicalTrigger == "super+=" && $0.actionName == "increase_font_size" })
    }
}
