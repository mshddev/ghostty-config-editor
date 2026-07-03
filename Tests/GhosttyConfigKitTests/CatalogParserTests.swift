import XCTest
@testable import GhosttyConfigKit

final class CatalogParserTests: XCTestCase {

    private func realCatalog() throws -> OptionCatalog {
        let text = try Fixture.text("show-config-default-docs", "txt")
        return CatalogParser.parse(text, version: "1.3.1")
    }

    // MARK: - Option count + known options (R1)

    func testParsesRepresentativeOptionCount() throws {
        let catalog = try realCatalog()
        // Real 1.3.1 output has 200 distinct option names; the macOS-scoped catalog
        // (R1, R6) drops 27 Linux/GTK-only options, leaving 173.
        XCTAssertEqual(catalog.options.count, 173)
        XCTAssertEqual(catalog.version, "1.3.1")
    }

    // MARK: - macOS-scoped catalog (R1, R6)

    func testMacOSScopedCatalogExcludesLinuxOnlyOptions() throws {
        let catalog = try realCatalog()
        // Linux-stack-prefixed options are gone.
        for name in ["gtk-titlebar", "gtk-custom-css", "x11-instance-name", "linux-cgroup"] {
            XCTAssertNil(catalog.option(named: name), "\(name) should be filtered from the macOS catalog")
        }
        // Doc-confirmed Linux/GTK/Wayland-only options without a Linux-stack prefix
        // are gone too.
        for name in ["app-notifications", "window-subtitle", "language", "async-backend",
                     "window-show-tab-bar", "quit-after-last-window-closed-delay",
                     "quick-terminal-keyboard-interactivity", "class", "freetype-load-flags",
                     "window-titlebar-background", "window-titlebar-foreground"] {
            XCTAssertNil(catalog.option(named: name), "\(name) is Linux/GTK-only and should be filtered")
        }
        // The "Linux / GTK" sidebar category disappears once its members are gone.
        XCTAssertFalse(catalog.categories.contains("Linux / GTK"))
    }

    func testMacOSScopedCatalogKeepsCrossPlatformAndMacOSOptions() throws {
        let catalog = try realCatalog()
        // desktop-notifications works on macOS (OSC 9/777) and must survive despite
        // sharing the "desktop"/notification theme with the filtered GTK options.
        XCTAssertNotNil(catalog.option(named: "desktop-notifications"),
                        "desktop-notifications is cross-platform and must be kept")
        // Kept, and grouped with the other notification settings via nameOverride.
        XCTAssertEqual(catalog.option(named: "desktop-notifications")?.category, "Notifications & Bell")
        // macOS-supported options that mention Linux in passing stay.
        for name in ["window-decoration", "window-save-state", "quick-terminal-space-behavior",
                     "macos-titlebar-style", "initial-window"] {
            XCTAssertNotNil(catalog.option(named: name), "\(name) is macOS-applicable and must be kept")
        }
    }

    func testMacOSCatalogScopePredicate() {
        // Prefix rule.
        XCTAssertTrue(MacOSCatalogScope.excludes("gtk-titlebar"))
        XCTAssertTrue(MacOSCatalogScope.excludes("x11-instance-name"))
        XCTAssertTrue(MacOSCatalogScope.excludes("linux-cgroup-hard-fail"))
        XCTAssertTrue(MacOSCatalogScope.excludes("wayland-anything"))
        // Curated non-prefixed rule.
        XCTAssertTrue(MacOSCatalogScope.excludes("app-notifications"))
        XCTAssertTrue(MacOSCatalogScope.excludes("window-subtitle"))
        XCTAssertTrue(MacOSCatalogScope.excludes("class"))
        XCTAssertTrue(MacOSCatalogScope.excludes("freetype-load-flags"))
        XCTAssertTrue(MacOSCatalogScope.excludes("window-titlebar-background"))
        // Kept: cross-platform / macOS / unrelated.
        XCTAssertFalse(MacOSCatalogScope.excludes("desktop-notifications"))
        XCTAssertFalse(MacOSCatalogScope.excludes("font-size"))
        XCTAssertFalse(MacOSCatalogScope.excludes("macos-titlebar-style"))
        XCTAssertFalse(MacOSCatalogScope.excludes("window-decoration"))
    }

    func testKnownOptionsArePresentWithDefaults() throws {
        let catalog = try realCatalog()
        XCTAssertNotNil(catalog.option(named: "font-family"))
        XCTAssertNotNil(catalog.option(named: "theme"))
        XCTAssertNotNil(catalog.option(named: "keybind"))

        let fontSize = catalog.option(named: "font-size")
        XCTAssertEqual(fontSize?.defaultValue, "13")
        XCTAssertEqual(fontSize?.valueType, .number)

        let opacity = catalog.option(named: "background-opacity")
        XCTAssertEqual(opacity?.defaultValue, "1")
        XCTAssertEqual(opacity?.valueType, .number)
    }

    // MARK: - Docs associate with the right option (R2)

    func testDocTextAssociatesWithCorrectOption() throws {
        let catalog = try realCatalog()
        let fontFamily = try XCTUnwrap(catalog.option(named: "font-family"))
        XCTAssertTrue(fontFamily.documentation.lowercased().contains("font famil"),
                      "font-family docs should describe font families")

        let cursorStyle = try XCTUnwrap(catalog.option(named: "cursor-style"))
        XCTAssertTrue(cursorStyle.documentation.lowercased().contains("valid values"))
    }

    func testDistinctKeysUnderOneDocBlockEachBecomeAnOption() throws {
        let catalog = try realCatalog()
        // font-family / -bold / -italic / -bold-italic share one doc block but
        // are four separate options.
        for name in ["font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic"] {
            XCTAssertNotNil(catalog.option(named: name), "expected \(name) to be its own option")
        }
    }

    // MARK: - Enum + type inference (R2)

    func testEnumValuesExtractedFromValidValuesSection() throws {
        let catalog = try realCatalog()
        let cursorStyle = try XCTUnwrap(catalog.option(named: "cursor-style"))
        XCTAssertEqual(cursorStyle.valueType, .enumeration)
        XCTAssertEqual(cursorStyle.enumValues, ["block", "bar", "underline", "block_hollow"])
        XCTAssertEqual(cursorStyle.defaultValue, "block")
    }

    func testEnumExtractionExcludesBlankBulletToken() throws {
        let catalog = try realCatalog()
        // cursor-style-blink documents a `(blank)` choice as `* \` \``; the blank
        // token must not leak into the enum.
        let blink = try XCTUnwrap(catalog.option(named: "cursor-style-blink"))
        XCTAssertFalse(blink.enumValues.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty },
                       "no whitespace-only enum value")
    }

    func testInlineAvailableValuesEnumIsExtracted() throws {
        let catalog = try realCatalog()
        // macos-titlebar-style documents choices inline ("Available values are: ...").
        let titlebar = try XCTUnwrap(catalog.option(named: "macos-titlebar-style"))
        XCTAssertEqual(titlebar.valueType, .enumeration)
        XCTAssertTrue(titlebar.enumValues.contains("transparent"))
        XCTAssertTrue(titlebar.enumValues.contains("hidden"))
    }

    // MARK: - Broadened enum detection (U1)

    func testValidValuesColonHeaderIsDetected() throws {
        let catalog = try realCatalog()
        // "Valid values:" (no "are") was previously missed → free text.
        let alpha = try XCTUnwrap(catalog.option(named: "alpha-blending"))
        XCTAssertEqual(alpha.valueType, .enumeration)
        XCTAssertEqual(alpha.enumValues, ["native", "linear", "linear-corrected"])

        let scrollbar = try XCTUnwrap(catalog.option(named: "scrollbar"))
        XCTAssertEqual(scrollbar.enumValues, ["system", "never"])

        let rightClick = try XCTUnwrap(catalog.option(named: "right-click-action"))
        XCTAssertEqual(rightClick.enumValues,
                       ["context-menu", "paste", "copy", "copy-or-paste", "ignore"])

        let newTab = try XCTUnwrap(catalog.option(named: "window-new-tab-position"))
        XCTAssertEqual(newTab.enumValues, ["current", "end"])
    }

    func testAllowableValuesHeaderIsDetected() throws {
        let catalog = try realCatalog()
        // "Allowable values are:" was previously missed.
        let osc = try XCTUnwrap(catalog.option(named: "osc-color-report-format"))
        XCTAssertEqual(osc.valueType, .enumeration)
        XCTAssertEqual(osc.enumValues, ["none", "8-bit", "16-bit"])
    }

    func testThreeValidValuesPhrasingIsDetected() throws {
        let catalog = try realCatalog()
        // "There are three valid values for this configuration:" — broad header match.
        let saveState = try XCTUnwrap(catalog.option(named: "window-save-state"))
        XCTAssertEqual(saveState.enumValues, ["default", "never", "always"])
    }

    func testCoListedBulletExtractsEveryValue() throws {
        let catalog = try realCatalog()
        // shell-integration co-lists `bash`, `elvish`, `fish`, `nushell`, `zsh` on
        // one bullet — the multi-token reader must keep them all.
        let shell = try XCTUnwrap(catalog.option(named: "shell-integration"))
        XCTAssertEqual(shell.valueType, .enumeration)
        XCTAssertEqual(shell.enumValues,
                       ["none", "detect", "bash", "elvish", "fish", "nushell", "zsh"])
    }

    func testContinuationLineValuesAreExtracted() throws {
        let catalog = try realCatalog()
        // macos-icon wraps `paper`, `retro`, `xray` onto a non-bulleted continuation
        // line after a dangling comma.
        let icon = try XCTUnwrap(catalog.option(named: "macos-icon"))
        XCTAssertEqual(icon.valueType, .enumeration)
        for value in ["official", "blueprint", "holographic", "paper", "retro", "xray",
                      "custom", "custom-style"] {
            XCTAssertTrue(icon.enumValues.contains(value), "macos-icon should offer \(value)")
        }
    }

    func testBooleanImpostorsWithBulletsBecomeEnumerations() throws {
        let catalog = try realCatalog()
        // Default `false` but the docs enumerate extra states → enum, not boolean.
        let fullscreen = try XCTUnwrap(catalog.option(named: "fullscreen"))
        XCTAssertEqual(fullscreen.valueType, .enumeration)
        XCTAssertTrue(fullscreen.enumValues.contains("non-native"))
        XCTAssertTrue(fullscreen.enumValues.contains("true"))
        XCTAssertTrue(fullscreen.enumValues.contains("false"))

        let nonNative = try XCTUnwrap(catalog.option(named: "macos-non-native-fullscreen"))
        XCTAssertEqual(nonNative.valueType, .enumeration)
        XCTAssertTrue(nonNative.enumValues.contains("visible-menu"))
        XCTAssertTrue(nonNative.enumValues.contains("padded-notch"))
    }

    func testColorPlaceholderValuesAreNotEnumerated() throws {
        let catalog = try realCatalog()
        // search-foreground documents "Valid values:" followed by `#RRGGBB`
        // placeholders — the literal-color guard + format rejection keep it free text.
        let searchFg = try XCTUnwrap(catalog.option(named: "search-foreground"))
        XCTAssertNotEqual(searchFg.valueType, .enumeration)
        XCTAssertTrue(searchFg.enumValues.isEmpty)

        let searchSel = try XCTUnwrap(catalog.option(named: "search-selected-foreground"))
        XCTAssertNotEqual(searchSel.valueType, .enumeration)
    }

    func testColorNamedOptionsWithRealEnumsSurvive() throws {
        let catalog = try realCatalog()
        // "color" in the name but a non-`#` default and a genuine closed set — the
        // value-literal color guard must NOT suppress these (regression guard).
        let padding = try XCTUnwrap(catalog.option(named: "window-padding-color"))
        XCTAssertEqual(padding.valueType, .enumeration)
        XCTAssertEqual(padding.enumValues, ["background", "extend", "extend-always"])

        let colorspace = try XCTUnwrap(catalog.option(named: "window-colorspace"))
        XCTAssertEqual(colorspace.valueType, .enumeration)
        XCTAssertEqual(colorspace.enumValues, ["srgb", "display-p3"])
    }

    func testExistingEnumsAreNotRegressed() throws {
        let catalog = try realCatalog()
        // Options detected before this change keep their exact value sets.
        XCTAssertEqual(catalog.option(named: "cursor-style")?.enumValues,
                       ["block", "bar", "underline", "block_hollow"])
        XCTAssertEqual(catalog.option(named: "mouse-shift-capture")?.enumValues,
                       ["true", "false", "always", "never"])
    }

    // MARK: - Curated fallback, inert filter, open-valued (U2)

    func testCuratedFallbackTypesProseOnlyImpostors() throws {
        let catalog = try realCatalog()
        let confirm = try XCTUnwrap(catalog.option(named: "confirm-close-surface"))
        XCTAssertEqual(confirm.valueType, .enumeration)
        XCTAssertEqual(confirm.enumValues, ["true", "false", "always"])

        let optionAsAlt = try XCTUnwrap(catalog.option(named: "macos-option-as-alt"))
        XCTAssertEqual(optionAsAlt.valueType, .enumeration)
        XCTAssertEqual(optionAsAlt.enumValues, ["true", "false", "left", "right"])

        // link-previews silently loses `osc8` today (mis-typed boolean).
        let links = try XCTUnwrap(catalog.option(named: "link-previews"))
        XCTAssertEqual(links.valueType, .enumeration)
        XCTAssertEqual(links.enumValues, ["true", "false", "osc8"])
    }

    func testGenuineBooleanAndCompositeNeighborsAreUntouched() throws {
        let catalog = try realCatalog()
        // A real two-state boolean in the impostor neighborhood stays boolean.
        XCTAssertEqual(catalog.option(named: "mouse-reporting")?.valueType, .boolean)
        // A composite comma-separated flag option is not single-choice → not enum.
        XCTAssertNotEqual(catalog.option(named: "shell-integration-features")?.valueType, .enumeration)
    }

    func testCompositeFlagOptionWithBulletedValuesStaysFreeText() throws {
        let catalog = try realCatalog()
        // bell-features documents its individual flags under "Valid values are:" so
        // the bullet reader would extract them, but its default is a comma-separated
        // flag list (`no-system,no-audio,attention,title,no-border`) with `no-`
        // negations — a single-select dropdown would silently drop flags on edit
        // (R4/KTD6/AE5). The comma-in-default guard keeps it free text.
        let bell = try XCTUnwrap(catalog.option(named: "bell-features"))
        XCTAssertNotEqual(bell.valueType, .enumeration)
        XCTAssertTrue(bell.enumValues.isEmpty)
    }

    func testParserResultWinsOverCuratedMap() throws {
        let catalog = try realCatalog()
        // cursor-style is parseable; the curated map must not override it.
        XCTAssertEqual(catalog.option(named: "cursor-style")?.enumValues,
                       ["block", "bar", "underline", "block_hollow"])
    }

    func testMacOSInertEnumValuesAreFiltered() throws {
        let catalog = try realCatalog()
        let theme = try XCTUnwrap(catalog.option(named: "window-theme"))
        XCTAssertEqual(theme.valueType, .enumeration)
        // `ghostty` is "only supported on Linux builds" → filtered on macOS.
        XCTAssertEqual(theme.enumValues, ["auto", "system", "light", "dark"])
        XCTAssertFalse(theme.enumValues.contains("ghostty"))
    }

    func testOpenValuedOptionsStayFreeTextWithReferenceValues() throws {
        let catalog = try realCatalog()
        // window-decoration also accepts boolean true/false beyond its named set →
        // free text, with the macOS-relevant values kept for the reference badge
        // (client/server are GTK-only and filtered out).
        let decoration = try XCTUnwrap(catalog.option(named: "window-decoration"))
        XCTAssertEqual(decoration.valueType, .string)
        XCTAssertEqual(decoration.enumValues, ["none", "auto"])

        // background-blur accepts any integer intensity → free text (would otherwise
        // infer `.boolean` from its `false` default and render a toggle).
        let blur = try XCTUnwrap(catalog.option(named: "background-blur"))
        XCTAssertEqual(blur.valueType, .string)
        XCTAssertTrue(blur.enumValues.contains("false"))
        XCTAssertTrue(blur.enumValues.contains("true"))
    }

    // MARK: - Repeatable keys (R9 foundation)

    func testRepeatableKeysAreRepresentedAsSuch() throws {
        let catalog = try realCatalog()
        let keybind = try XCTUnwrap(catalog.option(named: "keybind"))
        XCTAssertTrue(keybind.isRepeatable)
        XCTAssertGreaterThan(keybind.defaultValues.count, 1, "keybind has many default binds")

        let palette = try XCTUnwrap(catalog.option(named: "palette"))
        XCTAssertTrue(palette.isRepeatable)
        XCTAssertGreaterThanOrEqual(palette.defaultValues.count, 16, "palette defaults cover 0–15")
        XCTAssertEqual(palette.defaultValues.first, "0=#1d1f21")
    }

    // MARK: - Categories drive the sidebar (R3)

    func testCategoriesAreDerivedAndOrdered() throws {
        let catalog = try realCatalog()
        XCTAssertEqual(catalog.option(named: "font-size")?.category, "Font & Text")
        XCTAssertEqual(catalog.option(named: "keybind")?.category, OptionCategorizer.keybindingsCategory)
        XCTAssertEqual(catalog.option(named: "theme")?.category, "Appearance")
        // Appearance leads the newcomer-frequency order; nothing lands in "General".
        let cats = catalog.categories
        XCTAssertEqual(cats.first, "Appearance")
        XCTAssertTrue(cats.contains(OptionCategorizer.keybindingsCategory))
        XCTAssertFalse(cats.contains("General"))
    }

    // MARK: - Tolerance (R1 resilience)

    func testGarbledLinesAreToleratedNotFatal() {
        let messy = """
        # A good option
        good-option = yes

        this is not a config line at all
        =leading equals with no key
        # Another
        another = 1=2=3

        @@@ totally bogus @@@
        """
        let catalog = CatalogParser.parse(messy)
        XCTAssertNotNil(catalog.option(named: "good-option"))
        XCTAssertEqual(catalog.option(named: "another")?.defaultValue, "1=2=3")
        // The bogus lines produced no spurious options.
        XCTAssertEqual(catalog.options.count, 2)
    }

    func testValueWithEmbeddedEqualsPreserved() {
        let catalog = CatalogParser.parse("keybind = super+,=open_config")
        XCTAssertEqual(catalog.option(named: "keybind")?.defaultValue, "super+,=open_config")
    }

    // MARK: - Cache keyed by version (R1)

    func testCacheReusesParsedCatalogForSameVersion() async throws {
        let loadCount = LoadCounter()
        let provider = CatalogProvider { _ in
            await loadCount.increment()
            return "font-size = 13"
        }
        _ = try await provider.catalog(forVersion: "1.3.1")
        _ = try await provider.catalog(forVersion: "1.3.1")
        let count = await loadCount.value
        XCTAssertEqual(count, 1, "same version should load + parse only once")
    }

    func testCacheInvalidatesOnVersionChange() async throws {
        let loadCount = LoadCounter()
        let provider = CatalogProvider { _ in
            await loadCount.increment()
            return "font-size = 13"
        }
        _ = try await provider.catalog(forVersion: "1.3.1")
        _ = try await provider.catalog(forVersion: "1.4.0")
        let count = await loadCount.value
        XCTAssertEqual(count, 2, "a new version should trigger a reload")
    }
}

/// Counts loader invocations across actor boundaries.
private actor LoadCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
