import Foundation

/// How a row in the merged keybind list relates to Ghostty's defaults (RK1).
public enum KeybindOrigin: Sendable, Equatable {
    /// A Ghostty default the user has not touched.
    case `default`
    /// A user binding whose trigger is not among the defaults.
    case userAdded
    /// A user binding that re-binds a default's trigger to a different action.
    /// Carries the default's action so the UI can say "overrides X".
    case userOverridesDefault(defaultAction: String)
    /// A user `trigger=unbind` that disables a default.
    case userDisablesDefault
    /// An action Ghostty supports that has no binding at all — surfaced as an empty,
    /// bindable row so the editor lists the whole action set (like a system shortcuts
    /// pane), not just what's already bound.
    case unbound
}

/// One row of the editor's merged display: a default and/or a user binding,
/// resolved to a single trigger (RK1).
public struct MergedKeybind: Sendable, Equatable, Identifiable {
    /// Bound rows are unique by canonical trigger; an unbound-action row has no
    /// trigger, so it identifies by its action name instead (keeping SwiftUI ids
    /// unique across the ~39 empty rows).
    public var id: String { canonicalTrigger.isEmpty ? "action:\(action)" : canonicalTrigger }
    /// The trigger to display (the user's spelling when set, else the default's).
    public let trigger: String
    /// The action to display (the user's when set; the default's action for a
    /// disabled default).
    public let action: String
    public let canonicalTrigger: String
    public let origin: KeybindOrigin
    /// Where the user binding lives, when this row came from one (nil for an
    /// untouched default). Drives U5's out-of-target read-only marking (Risk R-F).
    public let source: SettingLocation?
    /// Extra **raw** triggers folded into this single capsule that must be edited/removed
    /// together with `trigger` (CB-digit): Ghostty ships `super+digit_N` *and* `super+N`
    /// for each tab, the same physical key on macOS. `collapsingRedundantDigits` hides the
    /// physical `super+digit_N` chord and records it here on the visible `⌘N` chord, so a
    /// rebind/turn-off disables BOTH lines rather than leaving the hidden one still firing.
    public let companions: [String]

    public init(trigger: String, action: String, canonicalTrigger: String, origin: KeybindOrigin, source: SettingLocation?, companions: [String] = []) {
        self.trigger = trigger
        self.action = action
        self.canonicalTrigger = canonicalTrigger
        self.origin = origin
        self.source = source
        self.companions = companions
    }

    /// A copy of this chord with more companion triggers folded in (see `companions`).
    public func addingCompanions(_ triggers: [String]) -> MergedKeybind {
        MergedKeybind(trigger: trigger, action: action, canonicalTrigger: canonicalTrigger,
                      origin: origin, source: source, companions: companions + triggers)
    }
}

/// One action's row in the editor (U17): the action plus **every chord bound to it**,
/// so Copy renders once carrying both ⌘C and the physical Copy key instead of as two
/// separate rows (KB-1). Each element of `chords` is one `MergedKeybind` — a single
/// trigger with its own origin and source, so conflict-at-capture and read-only-by-file
/// still evaluate per chord (two chords for one action can differ in origin/source).
///
/// A disabled default stays here as a struck chord (`.userDisablesDefault`) rather than
/// dropping the row (the LOCKED behavior flip, KB-2). An action with no shortcut at all
/// carries a single `.unbound` placeholder chord, so the whole action set still lists
/// like a system shortcuts pane.
public struct KeybindActionGroup: Sendable, Equatable, Identifiable {
    /// The full action string (params included) — unique per row, so it's the SwiftUI id.
    public var id: String { action }
    public let action: String
    /// The chords bound to this action, in listed order. Never empty.
    public let chords: [MergedKeybind]

    public init(action: String, chords: [MergedKeybind]) {
        self.action = action
        self.chords = chords
    }

    /// The action has no shortcut at all — its only chord is the empty `.unbound`
    /// placeholder, so the row shows a lone recorder rather than any struck capsule.
    public var isUnbound: Bool { chords.allSatisfy { $0.origin == .unbound } }

    /// The chords that currently fire: excludes the empty placeholder and any default the
    /// user turned off. Drives the truthful "N with a shortcut" header count (KB-7/CM-12).
    public var activeChords: [MergedKeybind] {
        chords.filter { $0.origin != .unbound && $0.origin != .userDisablesDefault }
    }

    /// Whether at least one chord is live (see `activeChords`).
    public var hasActiveShortcut: Bool { !activeChords.isEmpty }
}

/// A user's parsed `keybind` binding paired with where it was defined.
public struct UserKeybind: Sendable, Equatable {
    public let keybind: Keybind
    public let source: SettingLocation

    public init(keybind: Keybind, source: SettingLocation) {
        self.keybind = keybind
        self.source = source
    }

    public var canonicalTrigger: String { keybind.canonicalTrigger }
    /// A `trigger=unbind` binding disables a default rather than rebinding it.
    public var isUnbind: Bool { keybind.actionName == "unbind" }
}

/// Pure transforms that combine Ghostty defaults with the user's bindings (RK1)
/// and that produce the ordered write-list for the existing repeatable-key writer
/// (R9, AE2). Stateless namespace; see `TargetScopedBindings` for the write side.
public enum KeybindMerge {

    /// Parse the keybind `MergedOption`'s parallel `userValues`/`sources` into
    /// `UserKeybind`s, dropping whole-value specials (`clear`) which aren't
    /// per-trigger bindings. The writer still preserves those specials verbatim —
    /// see `TargetScopedBindings`.
    public static func userBindings(values: [String], sources: [SettingLocation], knownActions: Set<String> = []) -> [UserKeybind] {
        zip(values, sources).compactMap { value, source in
            guard case .binding(let bind) = Keybind.parse(value: value, knownActions: knownActions) else { return nil }
            return UserKeybind(keybind: bind, source: source)
        }
    }

    /// Join defaults with user bindings into the editor's display list (RK1).
    /// Defaults appear first in listed order (reflecting any override/disable in
    /// place); user-added bindings (triggers not among the defaults) follow in
    /// config order. When two user bindings share a canonical trigger the last
    /// wins, matching Ghostty.
    public static func merge(defaults rawDefaults: [DefaultKeybind], user: [UserKeybind]) -> [MergedKeybind] {
        // Defaults should be unique by canonical trigger, but a degenerate listing
        // (Risk R-B) could repeat one — collapse to the last (matches Ghostty)
        // so merged rows keep unique ids and SwiftUI never sees a duplicate.
        var lastDefaultIndex: [String: Int] = [:]
        for (index, def) in rawDefaults.enumerated() { lastDefaultIndex[def.canonicalTrigger] = index }
        let defaults = rawDefaults.enumerated()
            .filter { lastDefaultIndex[$0.element.canonicalTrigger] == $0.offset }
            .map(\.element)

        var userByTrigger: [String: UserKeybind] = [:]
        var firstSeenOrder: [String] = []
        for binding in user {
            let key = binding.canonicalTrigger
            if userByTrigger[key] == nil { firstSeenOrder.append(key) }
            userByTrigger[key] = binding   // last wins
        }

        let defaultTriggers = Set(defaults.map(\.canonicalTrigger))
        var rows: [MergedKeybind] = []

        for def in defaults {
            let key = def.canonicalTrigger
            guard let user = userByTrigger[key] else {
                rows.append(MergedKeybind(trigger: def.trigger, action: def.action,
                                          canonicalTrigger: key, origin: .default, source: nil))
                continue
            }
            if user.isUnbind {
                rows.append(MergedKeybind(trigger: def.trigger, action: def.action,
                                          canonicalTrigger: key, origin: .userDisablesDefault, source: user.source))
            } else {
                rows.append(MergedKeybind(trigger: user.keybind.trigger, action: user.keybind.action,
                                          canonicalTrigger: key,
                                          origin: .userOverridesDefault(defaultAction: def.action),
                                          source: user.source))
            }
        }

        for key in firstSeenOrder where !defaultTriggers.contains(key) {
            let user = userByTrigger[key]!
            rows.append(MergedKeybind(trigger: user.keybind.trigger, action: user.keybind.action,
                                      canonicalTrigger: key, origin: .userAdded, source: user.source))
        }

        return rows
    }

    /// Fold the per-chord merge output into one entry per action (U17). Each distinct
    /// action becomes a `KeybindActionGroup` carrying its chords in first-appearance
    /// order, so the list still reads defaults-first, then user-added, then the unbound
    /// tail — but Copy's two triggers now share one row. An action's disabled default is
    /// kept in place as a struck chord (it is not dropped before grouping — the LOCKED
    /// behavior flip, KB-2), and an otherwise-unbound action keeps its single `.unbound`
    /// placeholder chord.
    public static func group(_ merged: [MergedKeybind]) -> [KeybindActionGroup] {
        var order: [String] = []
        var chordsByAction: [String: [MergedKeybind]] = [:]
        for chord in merged {
            if chordsByAction[chord.action] == nil { order.append(chord.action) }
            chordsByAction[chord.action, default: []].append(chord)
        }
        return order.map { KeybindActionGroup(action: $0, chords: chordsByAction[$0]!) }
    }

    /// Collapse Ghostty's redundant physical/character digit pair into a single capsule
    /// (CB-digit). Ghostty ships both `super+digit_N` (the key by physical position) and
    /// `super+N` (the character) for every "Go to tab N" — the *same* physical key on macOS
    /// — which otherwise renders as two capsules, one reading the raw `⌘digit_N`. Hide the
    /// physical chord and fold its trigger onto the visible `⌘N` chord as a `companion`, so
    /// the row reads as a clean single `⌘N` while a rebind/turn-off/re-enable still applies
    /// to BOTH underlying lines (routed via `companions`).
    ///
    /// A pair folds only when both members share a collapsible **state** — both untouched
    /// defaults (`⌘N`), or both turned off (one struck `⌘N` with a single re-enable). A
    /// *diverged* pair (mixed origins, only reachable by hand-editing one line) stays split
    /// so the real state shows honestly.
    public static func collapsingRedundantDigits(_ groups: [KeybindActionGroup]) -> [KeybindActionGroup] {
        groups.map { group in
            let chords = group.chords
            // Index the character-digit chords (`super+N`) by "state + digit + modifiers",
            // so a physical chord only pairs with a character chord in the same state.
            var charIndexByKey: [String: Int] = [:]
            for (index, chord) in chords.enumerated() {
                guard let state = collapsibleStateTag(chord.origin),
                      let signature = characterDigitSignature(chord.trigger) else { continue }
                charIndexByKey["\(state)|\(signature)"] = index
            }
            guard !charIndexByKey.isEmpty else { return group }

            // Pair each physical-digit chord (`super+digit_N`) with its same-state character
            // sibling: drop the physical chord, remember it as a companion of the sibling.
            var companionsByCharIndex: [Int: [String]] = [:]
            var droppedIndices = Set<Int>()
            for (index, chord) in chords.enumerated() {
                guard let state = collapsibleStateTag(chord.origin),
                      let signature = physicalDigitSignature(chord.trigger),
                      let charIndex = charIndexByKey["\(state)|\(signature)"], charIndex != index else { continue }
                companionsByCharIndex[charIndex, default: []].append(chord.trigger)
                droppedIndices.insert(index)
            }
            guard !droppedIndices.isEmpty else { return group }

            let newChords = chords.enumerated().compactMap { index, chord -> MergedKeybind? in
                if droppedIndices.contains(index) { return nil }
                if let companions = companionsByCharIndex[index] { return chord.addingCompanions(companions) }
                return chord
            }
            return KeybindActionGroup(action: group.action, chords: newChords)
        }
    }

    /// The states whose physical+character digit pair may fold into one capsule: an
    /// untouched default, or a default the user turned off (both members disabled). Anything
    /// else — a rebind, a user-added binding, an unbound placeholder — keeps the pair split
    /// so a diverged/edited state is shown truthfully.
    private static func collapsibleStateTag(_ origin: KeybindOrigin) -> String? {
        switch origin {
        case .default: return "default"
        case .userDisablesDefault: return "disabled"
        default: return nil
        }
    }

    /// Signature `"N|mods"` for a bare (prefix-free, single-chord) *character* digit key
    /// like `super+1`; nil for anything else. Pairs with `physicalDigitSignature`.
    static func characterDigitSignature(_ trigger: String) -> String? {
        let parsed = KeybindTrigger.parse(trigger)
        guard parsed.prefixes.isEmpty, parsed.chords.count == 1 else { return nil }
        let chord = parsed.chords[0]
        let key = KeybindTrigger.canonicalizeKey(chord.key)
        guard key.count == 1, let character = key.first, character.isNumber else { return nil }
        return digitSignature(key, chord.modifiers)
    }

    /// Signature `"N|mods"` for a bare *physical* digit key like `super+digit_1`; nil
    /// otherwise. Same shape as `characterDigitSignature` so a pair matches by equality.
    static func physicalDigitSignature(_ trigger: String) -> String? {
        let parsed = KeybindTrigger.parse(trigger)
        guard parsed.prefixes.isEmpty, parsed.chords.count == 1 else { return nil }
        let chord = parsed.chords[0]
        let key = chord.key.trimmingCharacters(in: .whitespaces)
        let prefix = "digit_"
        guard key.hasPrefix(prefix) else { return nil }
        let digit = String(key.dropFirst(prefix.count))
        guard digit.count == 1, let character = digit.first, character.isNumber else { return nil }
        return digitSignature(digit, chord.modifiers)
    }

    private static func digitSignature(_ digit: String, _ modifiers: [KeyModifier]) -> String {
        "\(digit)|" + modifiers.map(\.rawValue).joined(separator: "+")
    }

    /// The action a chord would collide with: the action a *different* live chord already
    /// uses for `trigger`, or nil when the chord is free (or only used by `action` itself).
    /// Powers the conflict-at-capture prompt (F4, CONTROLS-10/11) — a rebind onto ⌘C should
    /// warn that Copy already uses it, before the after-the-fact lint bar. Scans **per
    /// chord** across the grouped rows: skips the empty placeholder and disabled defaults
    /// (whose trigger is actually free), and ignores the action being edited (recording a
    /// second trigger for the same action is not a conflict). Trigger matching is canonical,
    /// so `Super+C` collides with `super+c`.
    public static func conflictingAction(forTrigger trigger: String, excludingAction action: String, in groups: [KeybindActionGroup]) -> String? {
        let canonical = KeybindTrigger.parse(trigger).canonical()
        guard !canonical.isEmpty else { return nil }
        for group in groups where group.action != action {
            for chord in group.chords where chord.canonicalTrigger == canonical {
                if chord.origin == .unbound || chord.origin == .userDisablesDefault { continue }
                return group.action
            }
        }
        return nil
    }

    /// Actions that can't be bound with just a chord: `unbind` is the disable
    /// mechanism (not an action), and `text`/`csi`/`esc`/`cursor_key` are meaningless
    /// without a `:parameter` this editor has no inline picker for — so they are never
    /// listed as empty bindable rows. (When they *do* carry a param in an existing
    /// binding, that binding is a normal row and unaffected.)
    static let nonBindableActions: Set<String> = ["unbind", "text", "csi", "esc", "cursor_key"]

    /// Append an empty, bindable row for every action Ghostty supports that has no
    /// binding yet, so the editor lists the whole action set (like a system shortcuts
    /// pane) rather than only what's already bound. An action with *any* existing
    /// binding — even a disabled default — suppresses its unbound row. Sorted by name
    /// for a stable, scannable tail. A no-op when `allActions` is empty (the binary
    /// couldn't list them), so the editor still works against just the bound rows.
    public static func withUnboundActions(_ merged: [MergedKeybind], allActions: [KeybindAction]) -> [MergedKeybind] {
        let bound = Set(merged.map { Keybind.actionName($0.action) })
        // Dedupe by name via a Set (matching `merge`'s Risk R-B guard): a degenerate
        // `+list-actions` that repeats a name must not yield two `.unbound` rows sharing
        // the `action:<name>` SwiftUI id and tripping a duplicate-id fault after grouping.
        let unbound = Set(allActions.map(\.name))
            .subtracting(bound)
            .subtracting(nonBindableActions)
            .sorted()
            .map { MergedKeybind(trigger: "", action: $0, canonicalTrigger: "", origin: .unbound, source: nil) }
        return merged + unbound
    }
}

/// The user's keybind values **scoped to the writer's single target file**, plus
/// the pure edit operations that produce the next ordered `[String]` for
/// `AppModel.applyEdit(option:keybind, values:)` (KTD8).
///
/// Risk R-F: `ConfigReader.merge` accumulates a repeatable option's `userValues`
/// across the primary *and every include*, but `ConfigWriter` reconciles
/// position-wise against just one file. Feeding the full cross-file list to the
/// single-file writer would silently duplicate include-bindings into the primary.
/// Scoping the write-list to `ConfigWriter.targetFile(forOption:)`'s resolved path
/// keeps out-of-file bindings on disk untouched (U5 renders them read-only). All
/// values are kept **raw/verbatim** so the writer's reconcile leaves untouched
/// occurrences byte-identical (AE2, R8/R11).
public struct TargetScopedBindings: Sendable, Equatable {
    /// Every keybind value in the target file, in line order (raw/verbatim).
    public let rawValues: [String]
    /// Canonical trigger per value; nil for a non-binding special (`clear`), which
    /// is preserved as inert pass-through.
    private let canonicalTriggers: [String?]

    public init(userValues: [String], sources: [SettingLocation], targetResolvedPath: String, knownActions: Set<String> = []) {
        let target = ConfigReader.canonicalPath(targetResolvedPath)
        let scoped = zip(userValues, sources)
            .filter { ConfigReader.canonicalPath($0.1.file) == target }
            .sorted { $0.1.line < $1.1.line }
        self.rawValues = scoped.map(\.0)
        self.canonicalTriggers = scoped.map { value, _ in
            Keybind.parse(value: value, knownActions: knownActions).binding?.canonicalTrigger
        }
    }

    /// Test/seam initializer from already-scoped values.
    init(rawValues: [String], canonicalTriggers: [String?]) {
        self.rawValues = rawValues
        self.canonicalTriggers = canonicalTriggers
    }

    /// Edit an existing binding (identified by `originalTrigger`) or add a new one.
    /// When the trigger **changed**, the old entry is removed so a trigger edit
    /// *moves* the binding rather than leaving a duplicate behind (the orphan bug:
    /// R8/R11/RK4). `nil` (a brand-new binding) or an unchanged trigger behaves
    /// like an in-place add/update. The new value lands at the first slot that
    /// matched either the old or the new trigger, preserving order.
    public func updating(originalTrigger: String?, trigger: String, action: String) -> [String] {
        let newCanonical = KeybindTrigger.parse(trigger).canonical()
        let oldCanonical = originalTrigger.map { KeybindTrigger.parse($0).canonical() }
        let newValue = "\(trigger)=\(action)"
        var result: [String] = []
        var placed = false
        for (value, canon) in zip(rawValues, canonicalTriggers) {
            if canon == newCanonical || (oldCanonical != nil && canon == oldCanonical) {
                if !placed { result.append(newValue); placed = true }
                // drop any further duplicate of the old or new trigger
            } else {
                result.append(value)
            }
        }
        if !placed { result.append(newValue) }
        return result
    }

    /// **Move** a binding that currently comes from a Ghostty *default* (so there is
    /// no user line for it yet) to a new trigger: write `newTrigger=action` **and**
    /// disable the original with `oldTrigger=unbind`, so the action fires on the new
    /// keys only — not on both. This is what inline recording on a `.default` row does,
    /// matching the "rebind replaces the shortcut" expectation of a normal keybinding
    /// UI. Rebinding to the same canonical trigger is a no-op. Any existing user entry
    /// at the old or new trigger is collapsed (last-wins), and unrelated lines keep
    /// their verbatim raw text (AE2).
    public func movingDefault(fromTrigger oldTrigger: String, toTrigger newTrigger: String, action: String, alsoUnbind companions: [String] = []) -> [String] {
        let oldCanonical = KeybindTrigger.parse(oldTrigger).canonical()
        let newCanonical = KeybindTrigger.parse(newTrigger).canonical()
        // Recording the same keys the default already uses, with nothing else to disable:
        // nothing to move. (A merged capsule with companions still has work to do.)
        guard oldCanonical != newCanonical || !companions.isEmpty else { return rawValues }

        // Every default trigger to disable so the action fires on the new keys only — the
        // recorded one plus any merged companions (the physical `super+digit_N` sharing the
        // capsule). Keyed by canonical (for matching existing lines), valued by the raw
        // spelling (for a clean `super+digit_1=unbind`). Never disable the new trigger.
        var unbindRawByCanonical: [(canonical: String, raw: String)] = []
        var seenUnbind = Set<String>()
        for trigger in [oldTrigger] + companions {
            let canonical = KeybindTrigger.parse(trigger).canonical()
            guard canonical != newCanonical, seenUnbind.insert(canonical).inserted else { continue }
            unbindRawByCanonical.append((canonical, trigger))
        }
        let rawByCanonical = Dictionary(uniqueKeysWithValues: unbindRawByCanonical.map { ($0.canonical, $0.raw) })

        let newValue = "\(newTrigger)=\(action)"
        var result: [String] = []
        var placedNew = false
        var placedUnbind = Set<String>()
        for (value, canon) in zip(rawValues, canonicalTriggers) {
            if canon == newCanonical {
                if !placedNew { result.append(newValue); placedNew = true }
            } else if let canon, let raw = rawByCanonical[canon] {
                if placedUnbind.insert(canon).inserted { result.append("\(raw)=unbind") }
            } else {
                result.append(value)
            }
        }
        // Append unbinds not already present in the file, in a stable order.
        for (canonical, raw) in unbindRawByCanonical where placedUnbind.insert(canonical).inserted {
            result.append("\(raw)=unbind")
        }
        if !placedNew { result.append(newValue) }
        return result
    }

    /// Replace the target-file binding(s) with this canonical trigger, else append.
    /// Collapses duplicate-trigger entries to one (matches Ghostty's last-wins).
    public func addingOrUpdating(trigger: String, action: String) -> [String] {
        let canonical = KeybindTrigger.parse(trigger).canonical()
        let newValue = "\(trigger)=\(action)"
        var result: [String] = []
        var replaced = false
        for (value, canon) in zip(rawValues, canonicalTriggers) {
            if canon == canonical {
                if !replaced { result.append(newValue); replaced = true }
                // drop any further duplicate of the same trigger
            } else {
                result.append(value)
            }
        }
        if !replaced { result.append(newValue) }
        return result
    }

    /// Drop the binding(s) with this canonical trigger (a non-match is a no-op, so
    /// any default reactivates). Other values keep their verbatim raw text.
    public func removing(trigger: String) -> [String] {
        removing(triggers: [trigger])
    }

    /// Drop the binding(s) matching any of these canonical triggers — used to re-enable a
    /// merged capsule (CB-digit), where clearing the character's `=unbind` line must also
    /// clear the physical companion's, so both default keys reactivate together. Non-matches
    /// are no-ops; unrelated lines keep their verbatim raw text.
    public func removing(triggers: [String]) -> [String] {
        let canonicals = Set(triggers.map { KeybindTrigger.parse($0).canonical() })
        return zip(rawValues, canonicalTriggers).filter { _, canon in
            guard let canon else { return true }
            return !canonicals.contains(canon)
        }.map(\.0)
    }

    /// Disable a default by writing `trigger=unbind` — replacing an existing user
    /// binding for the trigger if present, else appending.
    public func unbindingDefault(trigger: String) -> [String] {
        addingOrUpdating(trigger: trigger, action: "unbind")
    }

    /// Disable several defaults at once (`trigger=unbind` for each), replacing any existing
    /// user line for those triggers. Used to turn off a merged physical+character digit pair
    /// together (CB-digit) so neither still fires. Each raw trigger is written verbatim
    /// (`super+digit_1=unbind`); matching against existing lines is canonical.
    public func unbindingDefaults(triggers: [String]) -> [String] {
        guard !triggers.isEmpty else { return rawValues }
        var rawByCanonical: [String: String] = [:]
        for trigger in triggers { rawByCanonical[KeybindTrigger.parse(trigger).canonical()] = trigger }

        var result: [String] = []
        var placed = Set<String>()
        for (value, canon) in zip(rawValues, canonicalTriggers) {
            if let canon, let raw = rawByCanonical[canon] {
                if placed.insert(canon).inserted { result.append("\(raw)=unbind") }
                // drop any further duplicate of the same trigger
            } else {
                result.append(value)
            }
        }
        // Append any that weren't already in the file, in the caller's order.
        for trigger in triggers {
            let canonical = KeybindTrigger.parse(trigger).canonical()
            if placed.insert(canonical).inserted { result.append("\(trigger)=unbind") }
        }
        return result
    }

    /// Revert an action to Ghostty's default by dropping every target-file line that
    /// (a) binds this action, or (b) `=unbind`s one of the action's default triggers
    /// (`defaultTriggers`, canonical) — so a rebind *and* the disable it wrote are both
    /// removed and the default reactivates. Backs "Restore default". Unrelated lines
    /// keep their verbatim raw text.
    public func removingAction(_ action: String, defaultTriggers: Set<String>, knownActions: Set<String> = []) -> [String] {
        // Match the *full* action (params included: `goto_split:previous`, not just
        // `goto_split`) so restoring one param variant doesn't wipe its siblings.
        zip(rawValues, canonicalTriggers).filter { value, canon in
            guard let bind = Keybind.parse(value: value, knownActions: knownActions).binding else { return true }
            if bind.action == action { return false }
            if bind.actionName == "unbind", let canon, defaultTriggers.contains(canon) { return false }
            return true
        }.map(\.0)
    }
}
