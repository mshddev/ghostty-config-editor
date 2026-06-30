import XCTest
@testable import GhosttyConfigKit

final class KeybindReferenceTests: XCTestCase {

    private func defaultsFixture() throws -> [DefaultKeybind] {
        let text = try Fixture.text("list-keybinds-default", "txt")
        let actions = try actionsFixture()
        return KeybindReference.parseDefaults(text, knownActions: Set(actions.map(\.name)))
    }

    private func actionsFixture() throws -> [KeybindAction] {
        KeybindReference.parseActions(try Fixture.text("list-actions", "txt"))
    }

    private func trigger(_ canonical: String, in defaults: [DefaultKeybind]) -> DefaultKeybind? {
        defaults.first { $0.canonicalTrigger == canonical }
    }

    // MARK: - Defaults (RK1)

    func testParsesRepresentativeDefaultCount() throws {
        let defaults = try defaultsFixture()
        // Real 1.3.1 `+list-keybinds --default --plain` lists 93 binds.
        XCTAssertEqual(defaults.count, 93)
    }

    func testParsesPlainDefaultLine() throws {
        let bind = try XCTUnwrap(trigger("super+shift+,", in: defaultsFixture()))
        XCTAssertEqual(bind.action, "reload_config")
    }

    func testParsesEqualsAndPlusKeyDefaults() throws {
        let defaults = try defaultsFixture()
        let eq = try XCTUnwrap(trigger("super+=", in: defaults))
        XCTAssertEqual(eq.action, "increase_font_size:1")
        let plus = try XCTUnwrap(trigger("super++", in: defaults))
        XCTAssertEqual(plus.action, "increase_font_size:1")
    }

    func testParsesParameterizedActionDefault() throws {
        let bind = try XCTUnwrap(trigger("super+ctrl+shift+j", in: defaultsFixture()))
        XCTAssertEqual(bind.action, "write_screen_file:copy,plain")
        XCTAssertEqual(bind.actionName, "write_screen_file")
    }

    /// `Covers RK1.` A sequence default isn't present in 1.3.1's listing, so this
    /// proves the parser round-trips one regardless (inline, like CatalogParser's
    /// inline edge-case tests).
    func testParsesSequenceDefaultLine() {
        let defaults = KeybindReference.parseDefaults("keybind = ctrl+a>n=new_tab", knownActions: ["new_tab"])
        XCTAssertEqual(defaults.count, 1)
        XCTAssertEqual(defaults.first?.trigger, "ctrl+a>n")
        XCTAssertEqual(defaults.first?.action, "new_tab")
    }

    // MARK: - Actions (RK2)

    func testParsesActionList() throws {
        let actions = try actionsFixture()
        // Real 1.3.1 `+list-actions` lists 85 actions.
        XCTAssertEqual(actions.count, 85)
        let names = Set(actions.map(\.name))
        for expected in ["ignore", "unbind", "new_tab", "goto_split"] {
            XCTAssertTrue(names.contains(expected), "expected action \(expected)")
        }
    }

    func testActionListIsDeduplicatedAndBlankTolerant() {
        let actions = KeybindReference.parseActions("""
        new_tab

        new_tab
        goto_split
        """)
        XCTAssertEqual(actions.map(\.name), ["new_tab", "goto_split"])
    }

    // MARK: - Tolerance (Risk R-B)

    func testMalformedLinesAreSkippedNotFatal() {
        let messy = """
        keybind = super+t=new_tab
        this is not a keybind line
        # a comment
        font-size = 13
        keybind =
        keybind = super+shift+t=unbind
        """
        let defaults = KeybindReference.parseDefaults(messy, knownActions: ["new_tab", "unbind"])
        // Two real bindings; the bare `keybind =` (clearAll special), the comment,
        // the non-keybind setting, and the prose line are all skipped.
        XCTAssertEqual(defaults.map(\.trigger), ["super+t", "super+shift+t"])
    }

    func testParserToleratesUnknownActionsWithoutASet() {
        // With no action set the shape heuristic still splits the boundary.
        let defaults = KeybindReference.parseDefaults("keybind = super+t=some_future_action")
        XCTAssertEqual(defaults.first?.trigger, "super+t")
        XCTAssertEqual(defaults.first?.action, "some_future_action")
    }

    // MARK: - Provider wiring (KTD2)

    func testProviderParsesAndCachesViaInjectedLoaders() async throws {
        let provider = KeybindReferenceProvider(
            loadDefaults: { "keybind = super+t=new_tab\nkeybind = super+w=close_surface" },
            loadActions: { "new_tab\nclose_surface" }
        )
        let actions = try await provider.actions()
        XCTAssertEqual(actions.map(\.name), ["new_tab", "close_surface"])
        let defaults = try await provider.defaults()
        XCTAssertEqual(defaults.map(\.trigger), ["super+t", "super+w"])
    }
}
