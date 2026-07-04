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

    // MARK: - Light/dark classification (E1)

    func testLuminanceOfBlackIsZeroAndWhiteIsOne() {
        XCTAssertEqual(ThemeParser.relativeLuminance(ofHex: "#000000")!, 0, accuracy: 0.001)
        XCTAssertEqual(ThemeParser.relativeLuminance(ofHex: "#ffffff")!, 1, accuracy: 0.001)
    }

    func testLuminanceAcceptsPrefixesAndShortAndAlphaForms() {
        XCTAssertEqual(ThemeParser.relativeLuminance(ofHex: "000")!, 0, accuracy: 0.001)
        XCTAssertEqual(ThemeParser.relativeLuminance(ofHex: "0xffffff")!, 1, accuracy: 0.001)
        // 8-digit rrggbbaa: alpha is ignored, still classifies on rgb.
        XCTAssertNotNil(ThemeParser.relativeLuminance(ofHex: "#ff880080"))
    }

    func testLuminanceReturnsNilForUnparseableColor() {
        XCTAssertNil(ThemeParser.relativeLuminance(ofHex: "cell-foreground"))
        XCTAssertNil(ThemeParser.relativeLuminance(ofHex: ""))
        XCTAssertNil(ThemeParser.relativeLuminance(ofHex: "#12"))
    }

    func testThemeAppearanceClassifiesDarkAndLightBackgrounds() {
        XCTAssertEqual(ThemeColors(background: "#1a1b26").appearance, .dark, "Tokyo Night is dark")
        XCTAssertEqual(ThemeColors(background: "#faf4ed").appearance, .light, "Rosé Pine Dawn is light")
    }

    func testThemeAppearanceIsNilWithoutParseableBackground() {
        XCTAssertNil(ThemeColors(background: nil).appearance)
        XCTAssertNil(ThemeColors(background: "not-a-color").appearance)
    }

    // MARK: - Name filter (E1)

    func testNameMatchesIsCaseAndDiacriticInsensitive() {
        XCTAssertTrue(ThemeParser.nameMatches("Tokyo Night", query: "tokyo"))
        XCTAssertTrue(ThemeParser.nameMatches("Rosé Pine", query: "rose"))
        XCTAssertTrue(ThemeParser.nameMatches("Rosé Pine", query: "ROSÉ"))
        XCTAssertFalse(ThemeParser.nameMatches("Tokyo Night", query: "dracula"))
    }

    func testNameMatchesEmptyOrWhitespaceQueryMatchesEverything() {
        XCTAssertTrue(ThemeParser.nameMatches("Anything", query: ""))
        XCTAssertTrue(ThemeParser.nameMatches("Anything", query: "   "))
    }

    // MARK: - Current selection membership (E2)

    func testSelectedThemeNamesSingle() {
        XCTAssertEqual(ThemeParser.selectedThemeNames("Aardvark Blue"), ["Aardvark Blue"])
    }

    func testSelectedThemeNamesPairIncludesBothMembers() {
        XCTAssertEqual(
            ThemeParser.selectedThemeNames("light:Rose Pine Dawn,dark:Rose Pine"),
            ["Rose Pine Dawn", "Rose Pine"]
        )
    }

    // MARK: - Light/dark pairing composition (E4)

    func testUpdatedPairingFromSingleSeedsTheUntouchedRole() {
        XCTAssertEqual(
            ThemeParser.updatedPairing(current: .single("0x96f"), setting: "Rosé Pine Dawn", as: .light),
            .lightDark(light: "Rosé Pine Dawn", dark: "0x96f"),
            "setting light keeps the current single as the dark member"
        )
        XCTAssertEqual(
            ThemeParser.updatedPairing(current: .single("0x96f"), setting: "Rosé Pine", as: .dark),
            .lightDark(light: "0x96f", dark: "Rosé Pine")
        )
    }

    func testUpdatedPairingPreservesTheOtherMemberOfAnExistingPair() {
        let current = ThemeSelection.lightDark(light: "L", dark: "D")
        XCTAssertEqual(
            ThemeParser.updatedPairing(current: current, setting: "Z", as: .dark),
            .lightDark(light: "L", dark: "Z"),
            "setting dark must not drop the existing light member"
        )
        XCTAssertEqual(
            ThemeParser.updatedPairing(current: current, setting: "Z", as: .light),
            .lightDark(light: "Z", dark: "D")
        )
    }

    func testUpdatedPairingWithNoCurrentThemeFillsBothSlots() {
        // A lone `dark:` isn't valid Ghostty light/dark syntax; `light:X,dark:X` ≡ X.
        XCTAssertEqual(
            ThemeParser.updatedPairing(current: nil, setting: "X", as: .dark),
            .lightDark(light: "X", dark: "X")
        )
    }

    func testUpdatedPairingRoundTripsThroughSerialize() {
        let selection = ThemeParser.updatedPairing(current: .single("A"), setting: "B", as: .light)
        XCTAssertEqual(ThemeParser.serialize(selection), "light:B,dark:A")
        XCTAssertEqual(ThemeParser.parseThemeSetting("light:B,dark:A"), selection)
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

    // MARK: - Terminal preview model (U14 / TH-2)

    func testPreviewModelUsesStatedColorsWhenPresent() {
        let colors = ThemeColors(
            palette: [2: "#00ff00", 4: "#0000ff"],
            background: "#101010", foreground: "#f0f0f0",
            cursorColor: "#ff00ff",
            selectionBackground: "#333333", selectionForeground: "#eeeeee"
        )
        let model = ThemePreviewModel.resolve(from: colors)
        XCTAssertEqual(model?.background, "#101010")
        XCTAssertEqual(model?.foreground, "#f0f0f0")
        XCTAssertEqual(model?.prompt, "#00ff00", "prompt uses palette green (2) when present")
        XCTAssertEqual(model?.output, "#0000ff", "output uses palette blue (4) when present")
        XCTAssertEqual(model?.cursor, "#ff00ff")
        XCTAssertEqual(model?.selectionBackground, "#333333")
        XCTAssertEqual(model?.selectionForeground, "#eeeeee")
    }

    func testPreviewModelResolvesEveryColorThroughFallbackChainForPaletteOnlyTheme() {
        // A theme that states only background/foreground and a partial palette — the
        // common upstream case where Ghostty derives cursor/selection at runtime.
        let colors = ThemeColors(background: "#1a1b26", foreground: "#c0caf5")
        let model = ThemePreviewModel.resolve(from: colors)
        XCTAssertNotNil(model, "background + foreground alone must resolve, never nil out")
        // cursor → foreground; selectionBackground → foreground; selectionForeground → background.
        XCTAssertEqual(model?.cursor, "#c0caf5")
        XCTAssertEqual(model?.selectionBackground, "#c0caf5")
        XCTAssertEqual(model?.selectionForeground, "#1a1b26")
        // No palette 2/4 → prompt and output both fall through to foreground.
        XCTAssertEqual(model?.prompt, "#c0caf5")
        XCTAssertEqual(model?.output, "#c0caf5")
    }

    func testPreviewModelPrefersBrightPaletteWhenNormalSlotMissing() {
        // Palette states only the bright slots (10 = bright green, 12 = bright blue).
        let colors = ThemeColors(palette: [10: "#5fff5f", 12: "#5f5fff"],
                                 background: "#000000", foreground: "#ffffff")
        let model = ThemePreviewModel.resolve(from: colors)
        XCTAssertEqual(model?.prompt, "#5fff5f", "prompt falls back to bright green (10)")
        XCTAssertEqual(model?.output, "#5f5fff", "output falls back to bright blue (12)")
    }

    func testPreviewModelReturnsNilWhenBackgroundOrForegroundMissing() {
        XCTAssertNil(ThemePreviewModel.resolve(from: ThemeColors(background: "#101010")),
                     "no foreground → placeholder, not an empty cell")
        XCTAssertNil(ThemePreviewModel.resolve(from: ThemeColors(foreground: "#f0f0f0")),
                     "no background → placeholder, not an empty cell")
        XCTAssertNil(ThemePreviewModel.resolve(from: ThemeColors(palette: [0: "#123456"])),
                     "palette alone can't render a terminal")
    }

    func testPreviewModelIsDeterministic() {
        let colors = ThemeColors(palette: [2: "#00ff00", 4: "#0000ff"],
                                 background: "#101010", foreground: "#f0f0f0")
        XCTAssertEqual(ThemePreviewModel.resolve(from: colors),
                       ThemePreviewModel.resolve(from: colors),
                       "same colors must yield the same model — no per-render randomness")
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
