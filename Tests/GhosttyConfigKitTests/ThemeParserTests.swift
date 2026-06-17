import XCTest
@testable import GhosttyConfigKit

final class ThemeParserTests: XCTestCase {

    // MARK: - Theme file colors (R12)

    func testRealThemeFileParsesIntoSixteenPaletteEntriesPlusBackgroundForeground() throws {
        let text = try Fixture.text("theme-aardvark-blue", "txt")
        let colors = ThemeParser.parseThemeFile(text)

        XCTAssertEqual(colors.palette.count, 16, "Aardvark Blue defines palette 0–15")
        XCTAssertEqual(colors.orderedPalette.count, 16)
        XCTAssertEqual(colors.palette[0], "#191919")
        XCTAssertEqual(colors.palette[15], "#f7f7f7")
        XCTAssertEqual(colors.background, "#102040")
        XCTAssertEqual(colors.foreground, "#dddddd")
        XCTAssertEqual(colors.cursorColor, "#007acc")
        XCTAssertEqual(colors.selectionBackground, "#bfdbfe")
    }

    // MARK: - Theme list (R12)

    func testThemeListEnumeratesWithPaths() throws {
        let output = try Fixture.text("list-themes-path", "txt")
        let themes = ThemeParser.parseThemeList(output)

        XCTAssertGreaterThan(themes.count, 100, "Ghostty ships hundreds of themes")
        let aardvark = themes.first { $0.name == "Aardvark Blue" }
        XCTAssertNotNil(aardvark)
        XCTAssertEqual(aardvark?.source, "resources")
        XCTAssertTrue(aardvark?.path.hasSuffix("/Aardvark Blue") ?? false,
                      "path should resolve to the theme file, including spaces")
    }

    func testThemeListHandlesNamesWithSpaces() throws {
        let themes = ThemeParser.parseThemeList(try Fixture.text("list-themes-path", "txt"))
        XCTAssertTrue(themes.contains { $0.name == "12-bit Rainbow" })
    }

    // MARK: - Fonts (R13)

    func testFontListParsesFamilyNames() throws {
        let fonts = ThemeParser.parseFontList(try Fixture.text("list-fonts", "txt"))
        XCTAssertTrue(fonts.contains("Andale Mono"))
        XCTAssertTrue(fonts.contains("Courier New"))
        // Indented style lines must not be treated as families.
        XCTAssertEqual(fonts, Array(NSOrderedSet(array: fonts)).map { $0 as! String },
                       "family list should be de-duplicated")
    }

    // MARK: - light/dark selection (R12)

    func testParseSingleThemeSetting() {
        XCTAssertEqual(ThemeParser.parseThemeSetting("Aardvark Blue"), .single("Aardvark Blue"))
    }

    func testParseLightDarkSettingRoundTrips() {
        let selection = ThemeParser.parseThemeSetting("light:Rose Pine Dawn,dark:Rose Pine")
        XCTAssertEqual(selection, .lightDark(light: "Rose Pine Dawn", dark: "Rose Pine"))
        XCTAssertEqual(ThemeParser.serialize(selection), "light:Rose Pine Dawn,dark:Rose Pine")
    }

    func testParseLightDarkIsOrderIndependent() {
        XCTAssertEqual(
            ThemeParser.parseThemeSetting("dark:Rose Pine,light:Rose Pine Dawn"),
            .lightDark(light: "Rose Pine Dawn", dark: "Rose Pine")
        )
    }

    // MARK: - Applying a theme writes the theme line (via U6)

    func testApplyingThemeWritesThemeLine() {
        let model = ConfigModel(primary: ConfigFile.parse(text: "font-size = 16\n", path: "/c", resolvedPath: "/c"))
        let edited = ConfigWriter().editedFile(setting: "theme", to: ["Aardvark Blue"], isRepeatable: false, in: model)
        XCTAssertEqual(edited.serialized(), "font-size = 16\ntheme = Aardvark Blue\n")
    }

    // MARK: - Fidelity disclaimer (R14)

    func testFidelityDisclaimerIsHonest() {
        let disclaimer = ThemeParser.previewFidelityDisclaimer.lowercased()
        XCTAssertTrue(disclaimer.contains("best-effort") || disclaimer.contains("approxim"))
        XCTAssertTrue(disclaimer.contains("ligature") || disclaimer.contains("font"))
    }

    // MARK: - ThemeProvider concurrency (review G4 #11)

    func testConcurrentColorLoadsDoNotSerializeOnTheActor() async throws {
        // A loadFile that blocks for 0.2s. If colors(for:) held the actor during
        // the read, five concurrent loads would serialize to ~1.0s; reading off
        // the actor lets them overlap to ~0.2s.
        let provider = ThemeProvider(
            loadList: { "" },
            loadFontList: { "" },
            loadFile: { _ in usleep(200_000); return "palette = 0=#000000\n" }
        )
        let themes = (0..<5).map { ThemeRef(name: "t\($0)", source: "user", path: "/tmp/theme-\($0)") }

        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for theme in themes {
                group.addTask { _ = try await provider.colors(for: theme) }
            }
            try await group.waitForAll()
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.7, "concurrent color loads must overlap, not serialize on the actor")
    }
}
