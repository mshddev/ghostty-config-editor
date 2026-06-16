import XCTest
@testable import GhosttyConfigKit

final class ConfigReaderTests: XCTestCase {

    private var catalog: OptionCatalog!
    private let reader = ConfigReader()

    override func setUpWithError() throws {
        let text = try Fixture.text("show-config-default-docs", "txt")
        catalog = CatalogParser.parse(text, version: "1.3.1")
    }

    private func model(_ text: String, path: String = "/tmp/config") -> ConfigModel {
        ConfigModel(primary: ConfigFile.parse(text: text, path: path, resolvedPath: path))
    }

    // MARK: - Line-preserving round trip (KTD5, R8/R11 foundation)

    func testRealUserConfigParsesWithoutLoss() throws {
        let text = try Fixture.text("user-config", "ghostty")
        let file = ConfigFile.parse(text: text, path: "config.ghostty", resolvedPath: "config.ghostty")
        XCTAssertEqual(file.serialized(), text, "config must round-trip byte-for-byte")
    }

    func testRoundTripPreservesTrailingNewlineState() {
        let withNL = ConfigFile.parse(text: "a = 1\n", path: "p")
        XCTAssertTrue(withNL.hasTrailingNewline)
        XCTAssertEqual(withNL.serialized(), "a = 1\n")

        let withoutNL = ConfigFile.parse(text: "a = 1", path: "p")
        XCTAssertFalse(withoutNL.hasTrailingNewline)
        XCTAssertEqual(withoutNL.serialized(), "a = 1")
    }

    func testCommentsBlanksAndUnknownLinesClassified() {
        let file = ConfigFile.parse(text: "# hi\n\nfont-size = 16\n@@@ junk", path: "p")
        XCTAssertEqual(file.lines.map(\.kind), [
            .comment,
            .blank,
            .setting(key: "font-size", value: "16"),
            .unparsed,
        ])
    }

    // MARK: - AE1: set vs unset display (R5, R6)

    func testAE1_SetNonDefaultAndUnsetAreDistinguished() throws {
        let merged = reader.merge(model: model("font-size = 16"), catalog: catalog)

        let fontSize = try XCTUnwrap(merged.option(named: "font-size"))
        XCTAssertEqual(fontSize.state, .setNonDefault)
        XCTAssertEqual(fontSize.userValues, ["16"])

        let cursorStyle = try XCTUnwrap(merged.option(named: "cursor-style"))
        XCTAssertEqual(cursorStyle.state, .unset)
        XCTAssertEqual(cursorStyle.effectiveValues, ["block"], "falls back to default")
        XCTAssertTrue(merged.unusedOptions.contains { $0.option.name == "cursor-style" },
                      "unset options appear in the discovery surface (R6)")
    }

    func testSetToDefaultIsNotFlaggedAsCustom() throws {
        let merged = reader.merge(model: model("cursor-style = block"), catalog: catalog)
        let cursorStyle = try XCTUnwrap(merged.option(named: "cursor-style"))
        XCTAssertEqual(cursorStyle.state, .setToDefault)
        XCTAssertFalse(merged.customizedOptions.contains { $0.option.name == "cursor-style" })
    }

    func testQuotedValueComparesEqualToUnquotedDefault() throws {
        // Default font-synthetic-style is `bold,italic,bold-italic`; quoting must
        // not make an otherwise-default value look customized.
        let merged = reader.merge(model: model("font-synthetic-style = \"bold,italic,bold-italic\""), catalog: catalog)
        XCTAssertEqual(merged.option(named: "font-synthetic-style")?.state, .setToDefault)
    }

    // MARK: - Additive keys (R9)

    func testRepeatableKeybindsCollectIntoList() throws {
        let cfg = """
        keybind = a=b
        keybind = c=d
        keybind = e=f
        keybind = g=h
        """
        let merged = reader.merge(model: model(cfg), catalog: catalog)
        let keybind = try XCTUnwrap(merged.option(named: "keybind"))
        XCTAssertEqual(keybind.userValues, ["a=b", "c=d", "e=f", "g=h"])
        XCTAssertEqual(keybind.sources.count, 4)
    }

    func testRealConfigKeybindsAndFontAreSet() throws {
        let text = try Fixture.text("user-config", "ghostty")
        let merged = reader.merge(model: model(text), catalog: catalog)

        XCTAssertEqual(merged.option(named: "font-size")?.state, .setNonDefault)
        XCTAssertEqual(merged.option(named: "font-family")?.state, .setNonDefault)
        let keybind = try XCTUnwrap(merged.option(named: "keybind"))
        XCTAssertEqual(keybind.userValues.count, 10, "the user has 10 keybinds")
    }

    func testUnknownUserKeysArePreservedAndSurfaced() {
        let merged = reader.merge(model: model("totally-made-up = 1\nfont-size = 16"), catalog: catalog)
        XCTAssertEqual(merged.unknownUserKeys, ["totally-made-up"])
    }

    // MARK: - Includes + precedence (R7, R5)

    func testConfigFileIncludesAreResolved() throws {
        let dir = try makeTempConfigDir()
        try write("config-file = extra.conf\n", to: dir, "config")
        try write("cursor-style = bar\n", to: dir, "extra.conf")

        let model = try reader.readModel(primaryPath: dir.appendingPathComponent("config").path)
        let merged = reader.merge(model: model, catalog: catalog)

        let cursorStyle = try XCTUnwrap(merged.option(named: "cursor-style"))
        XCTAssertEqual(cursorStyle.state, .setNonDefault)
        XCTAssertEqual(cursorStyle.userValues, ["bar"])
        XCTAssertTrue(cursorStyle.sources.first?.file.hasSuffix("extra.conf") ?? false,
                      "source should point at the include file")
    }

    func testIncludeAfterScalarOverridesByPrecedence() throws {
        let dir = try makeTempConfigDir()
        // primary sets 16, then includes a file that sets 20 → include wins (later).
        try write("font-size = 16\nconfig-file = extra.conf\n", to: dir, "config")
        try write("font-size = 20\n", to: dir, "extra.conf")

        let model = try reader.readModel(primaryPath: dir.appendingPathComponent("config").path)
        let merged = reader.merge(model: model, catalog: catalog)
        XCTAssertEqual(merged.option(named: "font-size")?.effectiveValues, ["20"])
    }

    func testScalarAfterIncludeWinsByPrecedence() throws {
        let dir = try makeTempConfigDir()
        // include first (sets 20), then primary sets 16 → primary wins (later).
        try write("config-file = extra.conf\nfont-size = 16\n", to: dir, "config")
        try write("font-size = 20\n", to: dir, "extra.conf")

        let model = try reader.readModel(primaryPath: dir.appendingPathComponent("config").path)
        let merged = reader.merge(model: model, catalog: catalog)
        XCTAssertEqual(merged.option(named: "font-size")?.effectiveValues, ["16"])
    }

    func testMissingOptionalIncludeIsSkipped() throws {
        let dir = try makeTempConfigDir()
        try write("config-file = ?does-not-exist.conf\nfont-size = 16\n", to: dir, "config")
        let model = try reader.readModel(primaryPath: dir.appendingPathComponent("config").path)
        let merged = reader.merge(model: model, catalog: catalog)
        XCTAssertEqual(merged.option(named: "font-size")?.effectiveValues, ["16"])
    }

    // MARK: - Path resolution

    func testConfigDirectoryHonorsXDG() {
        let dir = ConfigReader.configDirectory(environment: ["XDG_CONFIG_HOME": "/custom/cfg"], home: "/Users/x")
        XCTAssertEqual(dir.path, "/custom/cfg/ghostty")
    }

    func testConfigDirectoryFallsBackToHome() {
        let dir = ConfigReader.configDirectory(environment: [:], home: "/Users/x")
        XCTAssertEqual(dir.path, "/Users/x/.config/ghostty")
    }

    func testLocatePrefersCanonicalThenDotGhostty() throws {
        let dir = try makeTempConfigDir()
        try write("font-size = 1\n", to: dir, "config.ghostty")
        // only config.ghostty exists → it's found
        XCTAssertEqual(ConfigReader.locatePrimaryConfig(in: dir)?.lastPathComponent, "config.ghostty")
        // add canonical `config` → it now takes precedence
        try write("font-size = 2\n", to: dir, "config")
        XCTAssertEqual(ConfigReader.locatePrimaryConfig(in: dir)?.lastPathComponent, "config")
    }

    // MARK: - Helpers

    private func makeTempConfigDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostty-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ contents: String, to dir: URL, _ name: String) throws {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
