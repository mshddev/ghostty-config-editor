import Foundation

/// Ghostty's keybind trigger modifiers, in their canonical config spelling.
///
/// Ghostty requires modifiers lowercase and (when re-emitted) in a fixed order —
/// `super → ctrl → alt → shift` — regardless of the order the user typed them
/// (KTD4). `normalize` also folds the accepted aliases (`cmd`/`command`,
/// `control`, `opt`/`option`) onto the canonical token so a hand-written
/// `cmd+t` round-trips as `super+t`.
public enum KeyModifier: String, CaseIterable, Sendable, Equatable {
    case superKey = "super"
    case ctrl
    case alt
    case shift

    /// The fixed re-emission order (KTD4).
    public static let canonicalOrder: [KeyModifier] = [.superKey, .ctrl, .alt, .shift]

    /// The macOS glyph for this modifier, for DISPLAY ONLY (the config always stores
    /// the lowercase word). `super` is ⌘ on macOS (Ghostty maps the Command key to
    /// `super`).
    public var symbol: String {
        switch self {
        case .superKey: return "⌘"
        case .ctrl: return "⌃"
        case .alt: return "⌥"
        case .shift: return "⇧"
        }
    }

    /// Map a written modifier token (any case, including aliases) to its canonical
    /// form, or nil when the token is not a modifier (so the caller can treat it
    /// as the key).
    public static func normalize(_ token: String) -> KeyModifier? {
        switch token.lowercased() {
        case "super", "cmd", "command": return .superKey
        case "ctrl", "control": return .ctrl
        case "alt", "opt", "option": return .alt
        case "shift": return .shift
        default: return nil
        }
    }
}

/// A keybind trigger decomposed into its grammar pieces, preserving everything
/// the recorder can't regenerate so an unrelated edit never drops it (RK4).
///
/// Grammar (verified against Ghostty 1.3.1): `[<prefix>:]* <chord>[><chord>]*`
/// where a chord is `mod+mod+…+key`. Prefixes (`global:`/`all:`/`unconsumed:`/
/// `performable:`) and multi-chord sequences (`ctrl+a>n`) are preserved verbatim;
/// `=` and `+` are valid keys (`super+=`, `super++`).
public struct KeybindTrigger: Sendable, Equatable {
    /// A single chord: its modifier tokens *as written* plus the key token.
    public struct Chord: Sendable, Equatable {
        /// Modifier tokens exactly as the user wrote them (case preserved so
        /// validation can flag a non-lowercase modifier, KTD7).
        public let rawModifiers: [String]
        /// The key token, verbatim (`t`, `=`, `+`, `arrow_left`, `digit_1`, …).
        public let key: String

        public init(rawModifiers: [String], key: String) {
            self.rawModifiers = rawModifiers
            self.key = key
        }

        /// The written modifiers folded onto their canonical forms, in order,
        /// deduplicated. Unrecognized tokens are dropped (they can't be in
        /// `rawModifiers` after parsing, but this stays total).
        public var modifiers: [KeyModifier] {
            let present = Set(rawModifiers.compactMap(KeyModifier.normalize))
            return KeyModifier.canonicalOrder.filter(present.contains)
        }
    }

    /// Leading prefixes in order, each including its trailing colon (`global:`).
    public let prefixes: [String]
    /// One chord for a simple trigger; many for a `>`-joined sequence.
    public let chords: [Chord]

    public init(prefixes: [String], chords: [Chord]) {
        self.prefixes = prefixes
        self.chords = chords
    }

    /// Prefixes recognized at the front of a trigger, longest-stable set.
    static let knownPrefixes = ["global:", "all:", "unconsumed:", "performable:"]

    /// Decompose a trigger string. Never fails: an exotic/malformed trigger is
    /// still split as best as possible and preserved by `canonical()` only where
    /// it is well-formed (callers keep the original `raw` for verbatim round-trips).
    public static func parse(_ trigger: String) -> KeybindTrigger {
        var rest = trigger
        var prefixes: [String] = []
        prefixLoop: while true {
            for prefix in knownPrefixes where rest.hasPrefix(prefix) {
                prefixes.append(prefix)
                rest = String(rest.dropFirst(prefix.count))
                continue prefixLoop
            }
            break
        }
        // `>` separates sequence steps and is never a key (the recorder emits the
        // unshifted `.`, not `>`), matching Ghostty.
        let stepStrings = rest.split(separator: ">", omittingEmptySubsequences: false).map(String.init)
        let chords = stepStrings.map(parseChord)
        return KeybindTrigger(prefixes: prefixes, chords: chords)
    }

    /// Split one chord into modifier tokens + key. Consumes `+`-separated known
    /// modifiers left-to-right; the remainder is the key, so `+`/`=` survive as
    /// keys (`super++` → mods `[super]`, key `+`). Tokens are whitespace-trimmed so
    /// a hand-typed `super + t` parses the same as `super+t` (case is preserved on
    /// modifier tokens for validation).
    static func parseChord(_ step: String) -> Chord {
        var rest = Substring(step)
        var mods: [String] = []
        while let plus = rest.firstIndex(of: "+") {
            let token = rest[rest.startIndex..<plus].trimmingCharacters(in: .whitespaces)
            let tail = rest[rest.index(after: plus)...]
            // Only peel a leading token off as a modifier when it *is* one and
            // something remains to be the key; otherwise the rest (incl. a `+`
            // key) is the key.
            guard !tail.isEmpty, KeyModifier.normalize(token) != nil else { break }
            mods.append(token)
            rest = tail
        }
        return Chord(rawModifiers: mods, key: rest.trimmingCharacters(in: .whitespaces))
    }

    /// Re-emit the trigger canonically: prefixes verbatim, modifiers lowercased in
    /// `super→ctrl→alt→shift` order, single-character keys lowercased, sequences
    /// rejoined with `>` (RK4, KTD4).
    public func canonical() -> String {
        let prefixPart = prefixes.joined()
        let chordPart = chords.map { chord -> String in
            let mods = chord.modifiers.map(\.rawValue)
            return (mods + [Self.canonicalizeKey(chord.key)]).joined(separator: "+")
        }.joined(separator: ">")
        return prefixPart + chordPart
    }

    /// A macOS-symbol rendering of this trigger, for **display only** — modifiers
    /// become ⌘⌃⌥⇧ (in Ghostty's canonical `super→ctrl→alt→shift` order, matching how
    /// Mac apps stack them) joined with no `+`, while prefixes, the sequence `>` joins,
    /// and the key token are preserved (`super+shift+,` → `⌘⇧,`, `ctrl+a>n` → `⌃a>n`,
    /// `global:super+t` → `global:⌘t`). The config file always keeps the raw `super+…`
    /// tokens; this never round-trips back to disk.
    public func displaySymbol() -> String {
        let prefixPart = prefixes.joined()
        let chordPart = chords.map { chord -> String in
            // Thin spaces between the modifier glyphs and the key so the cluster
            // breathes (⌘ ⇧ , rather than a cramped ⌘⇧,); the key token is prettified
            // to its macOS glyph for display (↓, ⇞, ⌫, 1) but never for writing.
            (chord.modifiers.map(\.symbol) + [Self.displayKey(chord.key)])
                .joined(separator: "\u{2009}")
        }.joined(separator: ">")
        return prefixPart + chordPart
    }

    /// Convenience: parse a raw trigger then render it with macOS symbols.
    public static func displaySymbol(for trigger: String) -> String {
        parse(trigger).displaySymbol()
    }

    /// A "physical" named-key trigger: a bare, modifier-less named key such as the
    /// hardware Copy/Paste keys (`copy`, `paste`). These read as a distinct mono
    /// small-caps chip because a lone word can't lean on the ⌘⌃⌥⇧ glyph vocabulary a
    /// modified chord uses, so it would otherwise look like prose (KB-3/CB-6). A
    /// single-character key (`a`, `=`) is *not* physical — that's an ordinary key that
    /// only ever appears inside a modified chord. Sequences and prefixed triggers never
    /// qualify.
    public var isPhysicalNamedKey: Bool {
        guard prefixes.isEmpty, chords.count == 1 else { return false }
        let chord = chords[0]
        guard chord.modifiers.isEmpty else { return false }
        let key = Self.canonicalizeKey(chord.key)
        // Only keys with no conventional macOS glyph read as "prose" and need the chip;
        // arrows/backspace/etc. render as ↓/⌫ via `displayKey`, so they aren't "physical".
        return key.count > 1 && Self.displayGlyphs[key] == nil
    }

    /// Convenience: does this raw trigger render as a physical named-key chip?
    public static func isPhysicalNamedKey(_ trigger: String) -> Bool {
        parse(trigger).isPhysicalNamedKey
    }

    /// Lowercase only single-character keys (letters such as `T`→`t`, and
    /// layout-resolved characters); named keys (`arrow_left`) and punctuation
    /// (`=`, `[`) pass through unchanged. Whitespace is trimmed so a stray space
    /// can't make `super+t ` canonicalize differently from `super+t`.
    static func canonicalizeKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        return trimmed.count == 1 ? trimmed.lowercased() : trimmed
    }

    /// A **display-only** prettifying of a key token: Ghostty's named navigation and
    /// editing keys become their standard macOS glyphs (`arrow_down` → ↓, `page_up` → ⇞,
    /// `delete` → ⌫), so a shortcut reads like a Mac shortcut instead of a raw identifier.
    /// Everything without a conventional glyph (letters, punctuation, function keys) falls
    /// through to `canonicalizeKey`. **Never** used by `canonical()` — the raw token must
    /// survive for matching and writing (RK4), so this lives only behind `displaySymbol()`.
    ///
    /// Physical digit keys (`digit_1`) are deliberately *not* mapped: Ghostty ships both
    /// `super+digit_1` and `super+1` as defaults for `goto_tab:1`, so mapping `digit_1` → 1
    /// would render two identical `⌘1` capsules that read as a duplication bug. Left raw,
    /// the two chords at least stay visibly distinct.
    static func displayKey(_ key: String) -> String {
        let canonical = canonicalizeKey(key)
        return displayGlyphs[canonical] ?? canonical
    }

    // Keyed by the key names the recorder/Ghostty actually emit (see `namedKey` and
    // `+list-keybinds --default`): the ⌫ key is `backspace`, `delete` is the *forward*
    // delete, and the main Return key is `enter`. Getting these wrong renders real default
    // bindings (`super+backspace`, `super+enter`) with the wrong glyph or no glyph at all.
    private static let displayGlyphs: [String: String] = [
        "arrow_up": "↑", "arrow_down": "↓", "arrow_left": "←", "arrow_right": "→",
        "page_up": "⇞", "page_down": "⇟", "home": "↖", "end": "↘",
        "backspace": "⌫", "delete": "⌦", "escape": "⎋",
        "enter": "↩", "tab": "⇥", "space": "␣",
    ]
}

// MARK: - Captured key → token

/// A keystroke captured by the AppKit recorder, reduced to Sendable value types so
/// it can cross into the kit without importing AppKit (KTD1).
///
/// `resolvedCharacter` is the **unshifted, layout-correct** character the recorder
/// computed for a *character* key (letters, digits, punctuation) via the live
/// keyboard layout (KTD5); it is nil for position-stable named keys (arrows,
/// F-keys, enter/tab/…) which the kit names from `keyCode` instead.
public struct CapturedKey: Sendable, Equatable {
    public let keyCode: UInt16
    /// `NSEvent.modifierFlags.rawValue` (raw so the kit needs no AppKit type).
    public let modifierFlags: UInt
    public let resolvedCharacter: String?

    public init(keyCode: UInt16, modifierFlags: UInt, resolvedCharacter: String?) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.resolvedCharacter = resolvedCharacter
    }
}

public extension KeybindTrigger {
    // `NSEvent.ModifierFlags` raw bit values, re-declared so the kit stays
    // AppKit-free. `deviceIndependentFlagsMask` keeps only the high word so
    // hardware left/right-distinguishing bits don't leak in.
    private static let flagCapsLock: UInt = 1 << 16
    private static let flagShift: UInt    = 1 << 17
    private static let flagControl: UInt  = 1 << 18
    private static let flagOption: UInt   = 1 << 19
    private static let flagCommand: UInt  = 1 << 20
    private static let deviceIndependentMask: UInt = 0xffff_0000

    /// Build a canonical trigger token from a captured chord, or nil when the key
    /// can't be named (no resolved character and not a known named key) so the
    /// recorder keeps listening (KTD5).
    static func token(from key: CapturedKey) -> String? {
        let flags = key.modifierFlags & deviceIndependentMask
        var mods: [KeyModifier] = []
        // Append in canonical order directly. capsLock / function / numericPad
        // are intentionally ignored.
        if flags & flagCommand != 0 { mods.append(.superKey) }
        if flags & flagControl != 0 { mods.append(.ctrl) }
        if flags & flagOption != 0 { mods.append(.alt) }
        if flags & flagShift != 0 { mods.append(.shift) }

        let keyToken: String
        if let character = key.resolvedCharacter,
           !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A whitespace/control "character" (e.g. space or return mistakenly
            // resolved) is treated as absent so the position-stable named-key
            // table still names it (`space`/`enter`), not `super+ `.
            keyToken = character.lowercased()
        } else if let named = namedKey(forKeyCode: key.keyCode) {
            keyToken = named
        } else {
            return nil
        }
        return (mods.map(\.rawValue) + [keyToken]).joined(separator: "+")
    }

    /// Static `keyCode → Ghostty key name` table for **position-stable, non-character
    /// keys only** (KTD5). Letters, digits, and punctuation are layout-variable and
    /// must arrive via `CapturedKey.resolvedCharacter`, never from here. Names are
    /// Ghostty's own (verified against `+list-keybinds --default`: `enter`,
    /// `backspace`, `arrow_left`, `page_up`, …).
    static func namedKey(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 0x24: return "enter"
        case 0x30: return "tab"
        case 0x31: return "space"
        case 0x33: return "backspace"     // kVK_Delete is the Backspace key
        case 0x35: return "escape"
        case 0x75: return "delete"        // kVK_ForwardDelete
        case 0x73: return "home"
        case 0x77: return "end"
        case 0x74: return "page_up"
        case 0x79: return "page_down"
        case 0x7B: return "arrow_left"
        case 0x7C: return "arrow_right"
        case 0x7D: return "arrow_down"
        case 0x7E: return "arrow_up"
        case 0x7A: return "f1"
        case 0x78: return "f2"
        case 0x63: return "f3"
        case 0x76: return "f4"
        case 0x60: return "f5"
        case 0x61: return "f6"
        case 0x62: return "f7"
        case 0x64: return "f8"
        case 0x65: return "f9"
        case 0x6D: return "f10"
        case 0x67: return "f11"
        case 0x6F: return "f12"
        default: return nil
        }
    }
}

// MARK: - Keybind value

/// A parsed `keybind` value. The whole-value specials (`clear`, bare `keybind =`)
/// are not per-trigger bindings, so parsing yields either a `.binding` or a
/// `.special` and both carry the original `raw` for verbatim round-trips (R8/R11).
public enum ParsedKeybind: Sendable, Equatable {
    case binding(Keybind)
    case special(KeybindSpecial, raw: String)

    /// The original `keybind` value, preserved byte-for-byte for write-back.
    public var raw: String {
        switch self {
        case .binding(let keybind): return keybind.raw
        case .special(_, let raw): return raw
        }
    }

    public var binding: Keybind? {
        if case .binding(let keybind) = self { return keybind }
        return nil
    }
}

/// The non-binding whole-value forms of a `keybind` line.
public enum KeybindSpecial: Sendable, Equatable {
    /// A bare `keybind =` (empty value). Per Ghostty 1.3.1 this *resets to
    /// defaults* (see Risk R-A); the editor never generates it.
    case clearAll
    /// `keybind = clear`.
    case clear
}

/// A single `TRIGGER=ACTION` binding. `raw` is the exact original value (post the
/// `keybind = ` prefix) so an untouched binding round-trips byte-for-byte (AE2).
public struct Keybind: Sendable, Equatable {
    /// The trigger text as written (left of the action boundary).
    public let trigger: String
    /// The action text as written (right of the boundary), incl. any `:params`.
    public let action: String
    /// The full original value, preserved verbatim for the writer.
    public let raw: String

    public init(trigger: String, action: String, raw: String) {
        self.trigger = trigger
        self.action = action
        self.raw = raw
    }

    /// The canonical trigger spelling, used to match a user binding against a
    /// default and to dedupe (`Super+T` and `shift+super+t` both → `super+shift+t`).
    public var canonicalTrigger: String {
        KeybindTrigger.parse(trigger).canonical()
    }

    /// The action *name* without any `:params` (`write_screen_file:copy` → `write_screen_file`).
    public var actionName: String { Self.actionName(action) }

    static func actionName(_ action: String) -> String {
        let trimmed = action.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.firstIndex(of: ":") { return String(trimmed[..<colon]) }
        return trimmed
    }

    /// Parse a `keybind` value into a binding or a whole-value special.
    ///
    /// The `TRIGGER=ACTION` boundary cannot be found naively because `=` and `+`
    /// are valid keys (`super+==increase_font_size:1`). We scan candidate `=`
    /// positions left→right and take the first whose right-hand side names a
    /// *known action*; with no action set we fall back to the shape heuristic
    /// (action names are `[a-z_]`-initial), then to the last `=` (HTD, R-D).
    public static func parse(value: String, knownActions: Set<String> = []) -> ParsedKeybind {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .special(.clearAll, raw: value) }
        if trimmed.lowercased() == "clear" { return .special(.clear, raw: value) }

        let (trigger, action) = splitTriggerAction(trimmed, knownActions: knownActions)
        return .binding(Keybind(trigger: trigger, action: action, raw: value))
    }

    static func splitTriggerAction(_ value: String, knownActions: Set<String>) -> (trigger: String, action: String) {
        let eqIndices = value.indices.filter { value[$0] == "=" }
        guard !eqIndices.isEmpty else { return (value, "") }

        func split(at index: String.Index) -> (String, String) {
            // Trim each half so spaces around the boundary (`super+t = new_tab`)
            // don't leak into the trigger/action and break canonical matching.
            (String(value[..<index]).trimmingCharacters(in: .whitespaces),
             String(value[value.index(after: index)...]).trimmingCharacters(in: .whitespaces))
        }

        // 1) First boundary whose RHS is a *known* action (most precise).
        if !knownActions.isEmpty {
            for index in eqIndices {
                let (left, right) = split(at: index)
                guard !left.isEmpty, !right.isEmpty else { continue }
                if knownActions.contains(actionName(right)) { return (left, right) }
            }
        }
        // 2) First boundary whose RHS *looks like* an action name (no set available).
        for index in eqIndices {
            let (left, right) = split(at: index)
            guard !left.isEmpty, !right.isEmpty else { continue }
            if looksLikeActionName(actionName(right)) { return (left, right) }
        }
        // 3) Last resort: split on the final `=` so embedded `=` keys stay in the
        //    trigger rather than being mistaken for the boundary.
        let last = eqIndices.last!
        return split(at: last)
    }

    static func looksLikeActionName(_ name: String) -> Bool {
        guard let first = name.first, first == "_" || (first.isLetter && first.isLowercase) else { return false }
        return name.allSatisfy { $0 == "_" || $0.isNumber || ($0.isLetter && $0.isLowercase) }
    }
}

// MARK: - Validation (KTD7 / RK5)

/// A single validation issue produced before a keybind is written. Ghostty
/// *silently drops* malformed keybinds (exit 0, no stderr), so `+validate-config`
/// can't catch them — the kit validates trigger/action shape itself (KTD7).
public struct KeybindIssue: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        /// Ghostty would drop this binding — block the write.
        case error
        /// Valid but risky (e.g. a bare letter that fires on every keystroke).
        case warning
    }

    public let severity: Severity
    public let message: String

    public init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
    }
}

/// Pre-write validation of a trigger/action pair (RK5).
public enum KeybindValidation {

    /// Recognized special actions accepted even when the action set is empty
    /// (`+list-actions` unavailable). Parameterized forms (`text:…`) are matched
    /// by name.
    static let specialActions: Set<String> = ["unbind", "ignore", "text", "csi", "esc", "cursor_key"]

    /// Validate a trigger/action pair. Returns errors that would make Ghostty drop
    /// the binding plus softer warnings; an empty array means clean.
    public static func validate(trigger: String, action: String, knownActions: Set<String> = []) -> [KeybindIssue] {
        var issues: [KeybindIssue] = []
        let parsed = KeybindTrigger.parse(trigger)

        if parsed.chords.isEmpty || parsed.chords.contains(where: { $0.key.trimmingCharacters(in: .whitespaces).isEmpty }) {
            issues.append(KeybindIssue(severity: .error, message: "The trigger is missing a key."))
        }

        for chord in parsed.chords {
            for token in chord.rawModifiers where token != token.lowercased() {
                issues.append(KeybindIssue(severity: .error,
                                           message: "Modifier “\(token)” must be lowercase (e.g. \(token.lowercased()))."))
            }
            // A key token can't carry an `=` — that's the trigger/action boundary. Typing a
            // whole binding into the trigger-only text field (`ctrl+a=copy_to_clipboard`)
            // would otherwise be written as `ctrl+a=copy_to_clipboard=<action>`, a line
            // Ghostty silently drops. The bare `=` key (a single character) is legitimate.
            let key = chord.key.trimmingCharacters(in: .whitespaces)
            if key.count > 1, key.contains("=") {
                issues.append(KeybindIssue(severity: .error,
                                           message: "A shortcut can’t contain “=”. Enter only the keys (e.g. ctrl+a), not the action."))
            }
        }

        // A single-character chord with no real modifier fires on ordinary typing
        // — a footgun. Only flag a single chord (in a sequence the first key starts
        // the sequence, it doesn't fire per-press); Shift-only counts (Shift+a
        // fires when you type a capital A). Bare named keys (F5, arrows) are fine.
        if parsed.chords.count == 1, let only = parsed.chords.first, only.key.count == 1 {
            let mods = only.modifiers
            if mods.isEmpty {
                issues.append(KeybindIssue(severity: .warning,
                                           message: "“\(only.key)” has no modifier, so it fires on every press of that key."))
            } else if mods == [.shift] {
                issues.append(KeybindIssue(severity: .warning,
                                           message: "“\(only.key)” uses only Shift, so it fires whenever you type that character."))
            }
        }

        let name = Keybind.actionName(action)
        if name.isEmpty {
            issues.append(KeybindIssue(severity: .error, message: "The binding is missing an action."))
        } else if !knownActions.isEmpty, !knownActions.contains(name), !specialActions.contains(name) {
            issues.append(KeybindIssue(severity: .error, message: "“\(name)” isn’t a known Ghostty action."))
        }

        return issues
    }

    /// Convenience: true when nothing would make Ghostty drop the binding.
    public static func isWritable(trigger: String, action: String, knownActions: Set<String> = []) -> Bool {
        !validate(trigger: trigger, action: action, knownActions: knownActions).contains { $0.severity == .error }
    }
}
