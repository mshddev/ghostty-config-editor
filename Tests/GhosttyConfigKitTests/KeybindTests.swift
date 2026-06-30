import XCTest
@testable import GhosttyConfigKit

final class KeybindTests: XCTestCase {

    // NSEvent.ModifierFlags raw bit values, mirrored so the test needs no AppKit.
    private static let shift: UInt   = 1 << 17
    private static let control: UInt = 1 << 18
    private static let option: UInt  = 1 << 19
    private static let command: UInt = 1 << 20

    // macOS virtual key codes used in the named-key tests.
    private static let kEnter: UInt16 = 0x24
    private static let kF5: UInt16 = 0x60
    private static let kLeftArrow: UInt16 = 0x7B
    private static let kA: UInt16 = 0x00     // a *character* key — has no named-table entry

    // MARK: - Parse / serialize round-trip (R9, RK4)

    func testParseAndCanonicalRoundTripIsByteStable() {
        guard case .binding(let bind) = Keybind.parse(value: "super+shift+t=new_tab") else {
            return XCTFail("expected a binding")
        }
        XCTAssertEqual(bind.trigger, "super+shift+t")
        XCTAssertEqual(bind.action, "new_tab")
        XCTAssertEqual(bind.canonicalTrigger, "super+shift+t", "already-canonical trigger must be byte-stable")
    }

    func testMixedModifierOrderCanonicalizes() {
        let trigger = KeybindTrigger.parse("shift+alt+f")
        XCTAssertEqual(trigger.canonical(), "alt+shift+f")
    }

    func testEqualsKeyAndPlusKeyParseCorrectly() {
        guard case .binding(let eq) = Keybind.parse(value: "super+==increase_font_size:1") else {
            return XCTFail("expected a binding")
        }
        XCTAssertEqual(eq.trigger, "super+=")
        XCTAssertEqual(eq.action, "increase_font_size:1")
        XCTAssertEqual(eq.canonicalTrigger, "super+=")

        guard case .binding(let plus) = Keybind.parse(value: "super++=increase_font_size:1") else {
            return XCTFail("expected a binding")
        }
        XCTAssertEqual(plus.trigger, "super++")
        XCTAssertEqual(plus.canonicalTrigger, "super++")
    }

    func testParameterizedActionNameStripsParams() {
        guard case .binding(let bind) = Keybind.parse(value: "super+ctrl+shift+j=write_screen_file:copy,plain") else {
            return XCTFail("expected a binding")
        }
        XCTAssertEqual(bind.action, "write_screen_file:copy,plain")
        XCTAssertEqual(bind.actionName, "write_screen_file")
    }

    func testPrefixesArePreservedAndReEmittedAtFront() {
        guard case .binding(let bind) = Keybind.parse(value: "global:unconsumed:ctrl+a=reload_config") else {
            return XCTFail("expected a binding")
        }
        XCTAssertEqual(bind.trigger, "global:unconsumed:ctrl+a")
        let parsed = KeybindTrigger.parse(bind.trigger)
        XCTAssertEqual(parsed.prefixes, ["global:", "unconsumed:"])
        XCTAssertEqual(parsed.canonical(), "global:unconsumed:ctrl+a")
    }

    func testSequenceTriggerIsPreservedVerbatim() {
        guard case .binding(let bind) = Keybind.parse(value: "ctrl+a>n=new_tab") else {
            return XCTFail("expected a binding")
        }
        XCTAssertEqual(bind.trigger, "ctrl+a>n")
        XCTAssertEqual(bind.canonicalTrigger, "ctrl+a>n")
        XCTAssertEqual(KeybindTrigger.parse(bind.trigger).chords.count, 2)
    }

    func testSpecialWholeValuesAreRecognized() {
        guard case .binding(let unbind) = Keybind.parse(value: "super+shift+t=unbind") else {
            return XCTFail("expected a binding")
        }
        XCTAssertEqual(unbind.action, "unbind")

        XCTAssertEqual(Keybind.parse(value: "clear"), .special(.clear, raw: "clear"))
        XCTAssertEqual(Keybind.parse(value: ""), .special(.clearAll, raw: ""))
        XCTAssertEqual(Keybind.parse(value: "   "), .special(.clearAll, raw: "   "))
    }

    /// With a real action set the boundary resolves precisely even when the action
    /// shape heuristic would also fire elsewhere.
    func testKnownActionSetDisambiguatesBoundary() {
        let actions: Set<String> = ["increase_font_size", "reload_config"]
        guard case .binding(let bind) = Keybind.parse(value: "super+==increase_font_size:1", knownActions: actions) else {
            return XCTFail("expected a binding")
        }
        XCTAssertEqual(bind.trigger, "super+=")
        XCTAssertEqual(bind.action, "increase_font_size:1")
    }

    // MARK: - CapturedKey → token (RK3, KTD5)

    func testTokenFromCharacterKeyUsesResolvedCharacter() {
        let captured = CapturedKey(keyCode: 0x11, modifierFlags: Self.command | Self.shift, resolvedCharacter: "t")
        XCTAssertEqual(KeybindTrigger.token(from: captured), "super+shift+t")
    }

    func testTokenFromNonUSCharacterNeverSubstitutesUSPositionLetter() {
        // AZERTY: the recorder resolves the real character; the kit must use it
        // rather than a static keyCode→letter guess (KTD5).
        let captured = CapturedKey(keyCode: 0x11, modifierFlags: Self.command | Self.shift, resolvedCharacter: "é")
        XCTAssertEqual(KeybindTrigger.token(from: captured), "super+shift+é")
    }

    func testTokenFromPunctuationIsAResolvedCharacterNotTheStaticTable() {
        // `[` is layout-variable, so it must come through resolvedCharacter — a
        // QWERTZ user gets their actual bracket character, not the US one.
        let captured = CapturedKey(keyCode: 0x21, modifierFlags: Self.control, resolvedCharacter: "[")
        XCTAssertEqual(KeybindTrigger.token(from: captured), "ctrl+[")
    }

    func testTokenFromNamedKeysUsesStaticTable() {
        let enter = CapturedKey(keyCode: Self.kEnter, modifierFlags: Self.control, resolvedCharacter: nil)
        XCTAssertEqual(KeybindTrigger.token(from: enter), "ctrl+enter")

        let f5 = CapturedKey(keyCode: Self.kF5, modifierFlags: 0, resolvedCharacter: nil)
        XCTAssertEqual(KeybindTrigger.token(from: f5), "f5")

        let left = CapturedKey(keyCode: Self.kLeftArrow, modifierFlags: 0, resolvedCharacter: nil)
        XCTAssertEqual(KeybindTrigger.token(from: left), "arrow_left")
    }

    func testTokenLowercasesResolvedCharacter() {
        let captured = CapturedKey(keyCode: 0x11, modifierFlags: Self.command, resolvedCharacter: "T")
        XCTAssertEqual(KeybindTrigger.token(from: captured), "super+t")
    }

    func testTokenReturnsNilForUnnameableKey() {
        // A character key with no resolved character and no named-table entry: the
        // kit must NOT invent a letter from the keyCode.
        let captured = CapturedKey(keyCode: Self.kA, modifierFlags: Self.command, resolvedCharacter: nil)
        XCTAssertNil(KeybindTrigger.token(from: captured))
    }

    // MARK: - Validation (RK5, KTD7)

    func testValidationFlagsUppercaseUnknownAndNoModifier() {
        let actions: Set<String> = ["new_tab"]

        let upper = KeybindValidation.validate(trigger: "Super+t", action: "new_tab", knownActions: actions)
        XCTAssertTrue(upper.contains { $0.severity == .error }, "uppercase modifier is an error")

        let unknown = KeybindValidation.validate(trigger: "super+t", action: "frobnicate", knownActions: actions)
        XCTAssertTrue(unknown.contains { $0.severity == .error }, "unknown action is an error")

        let bare = KeybindValidation.validate(trigger: "t", action: "new_tab", knownActions: actions)
        XCTAssertTrue(bare.contains { $0.severity == .warning }, "modifier-less single key warns")
        XCTAssertFalse(bare.contains { $0.severity == .error }, "…but is not a hard error")

        let clean = KeybindValidation.validate(trigger: "super+t", action: "new_tab", knownActions: actions)
        XCTAssertTrue(clean.isEmpty, "a well-formed binding has no issues")
        XCTAssertTrue(KeybindValidation.isWritable(trigger: "super+t", action: "new_tab", knownActions: actions))
    }

    func testSpecialActionsValidateWithoutAKnownActionSet() {
        // `unbind` is accepted even when +list-actions wasn't available.
        XCTAssertTrue(KeybindValidation.isWritable(trigger: "super+shift+t", action: "unbind"))
        XCTAssertTrue(KeybindValidation.isWritable(trigger: "ctrl+a", action: "text:hello"))
    }

    func testEmptyKnownActionsDoesNotFlagUnknownAction() {
        // Without an action set we can't know an action is unknown — don't guess.
        let issues = KeybindValidation.validate(trigger: "super+t", action: "frobnicate")
        XCTAssertFalse(issues.contains { $0.severity == .error })
    }
}
