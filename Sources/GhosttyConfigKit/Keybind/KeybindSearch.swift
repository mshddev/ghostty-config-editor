import Foundation

/// Pure matching for the Keybindings editor's "search by pressing keys" (D): given a
/// captured chord, the action groups bound to exactly that chord. Kept out of the view so
/// the exact-match rule is unit-testable without an `NSEvent` recorder (KTD7).
public enum KeybindSearch {
    /// The action groups whose any chord's canonical trigger equals `chord` (exact match).
    ///
    /// The input is re-canonicalized so a freshly recorded token and a stored
    /// `canonicalTrigger` compare equal regardless of modifier order/spelling. Empty
    /// triggers (unbound rows) never match, and an empty/uncanonicalizable input matches
    /// nothing rather than everything.
    public static func groups(_ groups: [KeybindActionGroup], matchingChord chord: String) -> [KeybindActionGroup] {
        let target = KeybindTrigger.parse(chord).canonical()
        guard !target.isEmpty else { return [] }
        return groups.filter { group in
            group.chords.contains { !$0.canonicalTrigger.isEmpty && $0.canonicalTrigger == target }
        }
    }
}
