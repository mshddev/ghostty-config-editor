import XCTest
@testable import GhosttyConfigKit

/// Exact-chord matching behind the Keybindings "search by pressing keys" (D). The captured
/// token format is exactly what `KeybindTrigger.token(from:)` emits (`super+t`, canonical
/// modifier order, lowercased key) — the same shape as the stored `canonicalTrigger` — so
/// these use that spelling directly.
final class KeybindSearchTests: XCTestCase {

    private func group(_ action: String, trigger: String) -> KeybindActionGroup {
        KeybindActionGroup(action: action, chords: [
            MergedKeybind(trigger: trigger, action: action,
                          canonicalTrigger: KeybindTrigger.parse(trigger).canonical(),
                          origin: .default, source: nil)
        ])
    }

    private func unbound(_ action: String) -> KeybindActionGroup {
        KeybindActionGroup(action: action, chords: [
            MergedKeybind(trigger: "", action: action, canonicalTrigger: "", origin: .unbound, source: nil)
        ])
    }

    func testExactChordMatchesOnlyTheBoundAction() {
        let groups = [group("new_tab", trigger: "super+t"),
                      group("new_window", trigger: "super+n"),
                      unbound("toggle_quick_terminal")]
        XCTAssertEqual(KeybindSearch.groups(groups, matchingChord: "super+t").map(\.action), ["new_tab"],
                       "pressing ⌘T finds only new_tab")
    }

    func testMatchIsModifierOrderInsensitiveViaCanonicalization() {
        let groups = [group("close_window", trigger: "super+shift+w")]
        // A token written in a different modifier order still matches (both canonicalize).
        XCTAssertEqual(KeybindSearch.groups(groups, matchingChord: "shift+super+w").map(\.action),
                       ["close_window"])
    }

    func testAFreeCombinationMatchesNothing() {
        let groups = [group("new_tab", trigger: "super+t")]
        XCTAssertTrue(KeybindSearch.groups(groups, matchingChord: "super+shift+k").isEmpty,
                      "an unbound combo returns no results — which tells the user it's free")
    }

    func testEmptyChordMatchesNothingNotEverything() {
        let groups = [group("new_tab", trigger: "super+t"), unbound("x")]
        XCTAssertTrue(KeybindSearch.groups(groups, matchingChord: "").isEmpty)
    }

    func testMatchesOnAnyOfAnActionsChords() {
        let g = KeybindActionGroup(action: "new_tab", chords: [
            MergedKeybind(trigger: "super+t", action: "new_tab",
                          canonicalTrigger: KeybindTrigger.parse("super+t").canonical(),
                          origin: .default, source: nil),
            MergedKeybind(trigger: "ctrl+shift+t", action: "new_tab",
                          canonicalTrigger: KeybindTrigger.parse("ctrl+shift+t").canonical(),
                          origin: .default, source: nil),
        ])
        XCTAssertEqual(KeybindSearch.groups([g], matchingChord: "ctrl+shift+t").map(\.action), ["new_tab"],
                       "an action with two shortcuts matches on either")
    }
}
