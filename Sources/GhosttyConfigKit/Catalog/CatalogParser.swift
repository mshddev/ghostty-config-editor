import Foundation

/// Parses `ghostty +show-config --default --docs` into an `OptionCatalog`.
///
/// The output is a sequence of doc-comment blocks (lines starting with `#`)
/// followed by one or more `key = value` lines, with blank lines between blocks.
/// Two subtleties the parser must handle (both verified against real 1.3.1
/// output):
///   1. A single doc block can describe **several distinct keys** with no blank
///      line between them (e.g., `font-family`, `font-family-bold`, …). Each
///      becomes its own option sharing that block's docs.
///   2. A repeatable key emits **many lines with the same key** (`keybind`,
///      `palette`). Those collapse into one option carrying every default value.
public enum CatalogParser {

    /// Keys known to be additive/repeatable in Ghostty config (R9), even when
    /// the default output lists only one (often empty) value.
    private static let knownRepeatableKeys: Set<String> = [
        "keybind", "palette", "font-feature", "env",
        "font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic",
        "font-variation", "font-variation-bold", "font-variation-italic", "font-variation-bold-italic",
        "font-codepoint-map", "clipboard-codepoint-map", "config-file",
    ]

    /// Curated enum values for options whose finite value set appears only in
    /// prose — Ghostty's `--docs` express these without a parseable "Valid values"
    /// bulleted/inline form, so `extractEnumValues` cannot reach them. Each is a
    /// boolean *impostor* (a `true`/`false` default that accepts extra states),
    /// which `inferType` would otherwise mis-type `.boolean` and render as a
    /// two-state toggle that silently cannot represent — or preserve — the extra
    /// states. This is the deliberate, narrow exception to the self-describing
    /// catalog; membership criterion: a closed value set documented only in prose
    /// (verified against Ghostty 1.3.x — re-audit on upgrade, like
    /// `MacOSCatalogScope.nonPrefixedLinuxOnly`).
    private static let curatedEnumValues: [String: [String]] = [
        // "If set to `false` … This can also be set to `always`…"
        "confirm-close-surface": ["true", "false", "always"],
        // "If this is set to `false` … This can also be set to `always`…"
        "custom-shader-animation": ["true", "false", "always"],
        // "If `true`/`false` … The values `left` or `right` enable this for the
        // left or right Option key." (default is empty)
        "macos-option-as-alt": ["true", "false", "left", "right"],
        // Prose bullets `never`/`unfocused`/`always` with no "Valid values" header.
        "notify-on-command-finish": ["never", "unfocused", "always"],
        // "Example: `split-preserve-zoom = navigation`" + "prefixed with `no-`".
        "split-preserve-zoom": ["navigation", "no-navigation"],
        // "When true … When false … When set to \"osc8\"…"
        "link-previews": ["true", "false", "osc8"],
    ]

    /// Documented enum values that are inert on macOS, filtered from the dropdown
    /// so the catalog never offers a choice that does nothing here (mirrors the
    /// macOS-scoped-catalog identity, which otherwise filters whole options).
    /// `MacOSCatalogScope` filters options, not individual values; the CLI carries
    /// no per-value platform tag, so this is curated from the value's own `--docs`
    /// platform-restriction language (verified against Ghostty 1.3.x).
    private static let macOSInertEnumValues: [String: Set<String>] = [
        "window-theme": ["ghostty"],            // "only supported on Linux builds"
        "window-decoration": ["client", "server"], // client/server-side decorations are GTK/X11/Wayland
    ]

    /// Options that accept `true`/`false` *alongside* other values — boolean
    /// impostors (`confirm-close-surface`) and open-valued booleans
    /// (`background-blur`). The editor should present these toggle-first, exposing
    /// the extra states secondarily (U10), rather than as a bare dropdown/field.
    /// This is a *presentation hint only* — `valueType` is left untouched, so the
    /// underlying `.enumeration`/`.string` typing (and its lossless editing) is
    /// preserved. Curated + version-audited like `curatedEnumValues` /
    /// `openValuedOptions`.
    private static let booleanishOptions: Set<String> = [
        "confirm-close-surface",
        "custom-shader-animation",
        "macos-option-as-alt",
        "link-previews",
        "window-decoration",
        "background-blur",
        // Tri-state (true / false / unset-null). Presented toggle-first so a raw "true"
        // never renders in a picker (CV-5); the unset/null state stays reachable via the
        // row's reset, and true/false are the on/off axis.
        "cursor-style-blink",
    ]

    /// True when an option accepts `true`/`false` among other values, so the editor
    /// renders toggle-first (U10). A plain `.boolean` option is *not* flagged — its
    /// type already implies a toggle.
    public static func isBooleanish(_ name: String) -> Bool {
        booleanishOptions.contains(name)
    }

    /// Options that document a finite value set but also accept values *beyond*
    /// it, so a closed dropdown would be wrong. They keep a free-text editor (the
    /// documented values still show as a read-only reference). Verified against
    /// Ghostty 1.3.x — re-audit on upgrade.
    private static let openValuedOptions: Set<String> = [
        // "this setting also accepts boolean true and false values" on top of
        // none/auto/client/server.
        "window-decoration",
        // "Valid values are: a nonnegative integer …, `false`, `true`" — accepts
        // any integer blur intensity, not just the listed keywords.
        "background-blur",
    ]

    /// Mutable accumulator while parsing.
    private struct Builder {
        var name: String
        var defaultValues: [String]
        var documentation: String
    }

    public static func parse(_ text: String, version: String? = nil) -> OptionCatalog {
        var order: [String] = []
        var builders: [String: Builder] = [:]

        var pendingDocLines: [String] = []
        var inValueRun = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#") {
                // A comment after a value run begins a new block → reset docs.
                if inValueRun {
                    pendingDocLines = []
                    inValueRun = false
                }
                pendingDocLines.append(stripCommentMarker(line))
                continue
            }

            if trimmed.isEmpty {
                // Blank line ends the current block.
                pendingDocLines = []
                inValueRun = false
                continue
            }

            guard let (key, value) = ConfigLine.splitSetting(line) else {
                // Tolerate garbled / unexpected lines (skip, never fatal).
                continue
            }

            inValueRun = true
            if builders[key] != nil {
                builders[key]!.defaultValues.append(value)
            } else {
                order.append(key)
                builders[key] = Builder(
                    name: key,
                    defaultValues: [value],
                    // Distinct keys sharing a doc block all inherit it; docs are
                    // intentionally NOT reset between value lines of a run.
                    documentation: joinDocs(pendingDocLines)
                )
            }
        }

        let options = order.compactMap { name -> CatalogOption? in
            guard let b = builders[name] else { return nil }
            // macOS-scoped catalog (R1, R6): drop options that only take effect on
            // Linux/GTK so they never surface in browse/search/discovery. See
            // `MacOSCatalogScope`.
            guard !MacOSCatalogScope.excludes(name) else { return nil }
            let defaultValue = b.defaultValues.first ?? ""
            let enums = resolvedEnumValues(name: name, default: defaultValue, documentation: b.documentation)
            let repeatable = b.defaultValues.count > 1 || knownRepeatableKeys.contains(name)
            // Open-valued options keep their documented values for the reference
            // badge but are typed free-text (`.string`) so the editor offers a text
            // field, not a lossy closed dropdown. (Forcing `.string` rather than
            // letting `inferType` run with an empty enum matters for
            // `background-blur`, whose `false` default would otherwise infer
            // `.boolean` and render a two-state toggle.)
            let valueType: OptionValueType = openValuedOptions.contains(name)
                ? .string
                : inferType(name: b.name, default: defaultValue, enums: enums)
            return CatalogOption(
                name: b.name,
                defaultValues: b.defaultValues,
                documentation: b.documentation,
                category: OptionCategorizer.category(for: b.name),
                valueType: valueType,
                enumValues: enums,
                isRepeatable: repeatable
            )
        }

        return OptionCatalog(options: options, version: version)
    }

    // MARK: - Docs

    private static func stripCommentMarker(_ line: String) -> String {
        if line == "#" { return "" }
        if line.hasPrefix("# ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("#") { return String(line.dropFirst(1)) }
        return line
    }

    private static func joinDocs(_ lines: [String]) -> String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Enum extraction

    /// The catalog's final enum values for an option: parse the docs, fall back to
    /// the curated map for prose-only impostors, drop macOS-inert values, and
    /// suppress the whole set for a literal-color option. The view derives its
    /// control from these (and `valueType`) and never re-inspects doc text (R7).
    private static func resolvedEnumValues(name: String, default def: String, documentation: String) -> [String] {
        // A literal-color default (`#RRGGBB`) means any bulleted "Valid values" are
        // format placeholders, not a closed set — never enumerate it. Guarding on
        // the default *value* (not the option name) is deliberate: `window-padding-color`,
        // `window-colorspace`, and `osc-color-report-format` all carry "color" in
        // their name yet enumerate a genuine closed set.
        if def.hasPrefix("#") { return [] }
        // A comma-separated default marks a composite multi-flag value
        // (`bell-features = no-system,no-audio,…`): these combine flags (often with
        // `no-` negations) rather than pick one, so a single-select dropdown would
        // silently drop the other flags the moment the user edits it (R4/KTD6).
        // Keep them free text — value-based so it catches future composite options
        // without a curated list.
        if def.contains(",") { return [] }
        let parsed = extractEnumValues(documentation)
        // Curated map only fills gaps — a real parser result always wins.
        let documented = parsed.isEmpty ? (curatedEnumValues[name] ?? []) : parsed
        let scoped: [String]
        if let inert = macOSInertEnumValues[name] {
            scoped = documented.filter { !inert.contains($0) }
        } else {
            scoped = documented
        }
        // Re-apply the two-choice floor after inert filtering, so a future option
        // whose set collapses to a single macOS-relevant value doesn't render a
        // degenerate one-item dropdown.
        return scoped.count >= 2 ? scoped : []
    }

    /// Pull enumerated values from a doc section. Handles both Ghostty doc styles:
    ///  - bulleted: a "Valid values" / "Allowable values" header followed by
    ///              `* \`block\`` lines (with or without "are"/colon, possibly
    ///              preceded by prose, e.g. "…of the window. Valid values are:")
    ///  - inline:   "Available values are: \"native\", \"transparent\", …"
    ///
    /// Bulleted values are read as the *leading run of backtick tokens* on each
    /// bullet, because Ghostty co-lists several choices on one bullet
    /// (`shell-integration`: `* \`bash\`, \`elvish\`, \`fish\`, … - description`) and
    /// even wraps them onto a non-bulleted continuation line (`macos-icon`'s
    /// `paper`/`retro`/`xray`). Reading only the first token would silently render a
    /// *closed dropdown missing legal values* — the inverse of the bug this fixes.
    ///
    /// False positives are guarded out: extraction stops at the first prose
    /// character (so a backticked token inside a bullet's description is not
    /// pulled), format placeholders are rejected (`#RRGGBB`, `RRGGBB`, `N=COLOR`),
    /// and a set with fewer than two real values yields nothing. The
    /// "never enumerate a literal-color option" guard lives at the `parse` call
    /// site (it needs the option's default, which this function does not see).
    static func extractEnumValues(_ documentation: String) -> [String] {
        enum Mode { case none, bulleted, inline }
        var values: [String] = []
        var mode: Mode = .none
        // True when the previous bullet's value run ended on a dangling comma,
        // so an immediately-following non-bullet line continues the list.
        var continuingRun = false

        for rawLine in documentation.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            // Bulleted header. Broad on purpose ("valid values" with or without
            // "are"/colon, "allowable values"); a stray match in prose is harmless
            // because no backtick bullets follow it and the >=2-real-values floor
            // (below) drops anything degenerate.
            if lower.contains("valid values") || lower.contains("allowable values") {
                mode = .bulleted
                continuingRun = false
                continue
            }
            if lower.contains("available values are") || lower.contains("possible values are") {
                // Inline form: quoted choices on this and following lines until a
                // paragraph break (the list often wraps across lines).
                mode = .inline
                values.append(contentsOf: quotedTokens(line))
                continue
            }
            switch mode {
            case .none:
                continue
            case .bulleted:
                if line.hasPrefix("* ") || line.hasPrefix("- ") {
                    let run = valueRun(from: String(line.dropFirst(2)))
                    values.append(contentsOf: run.values)
                    continuingRun = run.open
                } else if continuingRun, line.hasPrefix("`") {
                    // Wrapped continuation of a co-listed bullet.
                    let run = valueRun(from: line)
                    values.append(contentsOf: run.values)
                    continuingRun = run.open
                } else {
                    // Blank/prose (e.g. a wrapped bullet description) does not
                    // terminate the list, but it does end any open continuation.
                    continuingRun = false
                }
            case .inline:
                if line.isEmpty { mode = .none } // paragraph break ends the inline list
                else { values.append(contentsOf: quotedTokens(line)) }
            }
        }

        var seen = Set<String>()
        let cleaned = values
            .filter { !isFormatPlaceholder($0) }
            .filter { seen.insert($0).inserted }
        // A genuine enumerated set has at least two choices; a lone survivor is
        // almost always a format example (e.g. a stray `#RRGGBB`).
        return cleaned.count >= 2 ? cleaned : []
    }

    /// Read the leading run of backtick-quoted values from a bullet's content,
    /// e.g. "\`bash\`, \`elvish\`, \`zsh\` - description" → (["bash","elvish","zsh"], open: false).
    /// Stops at the first character that is not a backtick token, comma, or space
    /// (i.e. the start of a prose description). `open` is true when the run ends on
    /// a dangling comma at end-of-content, signalling the list wraps onto the next
    /// line (`macos-icon`). A bullet that begins with prose yields no values.
    private static func valueRun(from content: String) -> (values: [String], open: Bool) {
        var values: [String] = []
        var idx = content.startIndex
        var endedOnComma = false
        while idx < content.endIndex {
            // Skip spaces and commas between tokens.
            while idx < content.endIndex, content[idx] == " " || content[idx] == "," {
                if content[idx] == "," { endedOnComma = true }
                idx = content.index(after: idx)
            }
            guard idx < content.endIndex else { break }
            // Prose: the value run is terminated, not continued onto the next line.
            guard content[idx] == "`" else { return (values, false) }
            let afterOpen = content.index(after: idx)
            guard let close = content[afterOpen...].firstIndex(of: "`") else { break }
            let token = String(content[afterOpen..<close]).trimmingCharacters(in: .whitespaces)
            if !token.isEmpty { values.append(token) }
            endedOnComma = false
            idx = content.index(after: close)
        }
        return (values, endedOnComma)
    }

    /// Reject format stand-ins that look like values but aren't a closed set —
    /// color/format placeholders (`#RRGGBB`, `RRGGBB`, `N=COLOR`) and anything
    /// containing whitespace. Real Ghostty values are lowercase kebab-case
    /// (`linear-corrected`, `copy-or-paste`, `8-bit`), never all-caps.
    private static func isFormatPlaceholder(_ token: String) -> Bool {
        if token.isEmpty { return true }
        if token.contains(" ") || token.contains("#") || token.contains("=") { return true }
        if token.count >= 2,
           token.allSatisfy(\.isLetter),
           token == token.uppercased(),
           token != token.lowercased() {
            return true
        }
        return false
    }

    /// Extract double-quoted or backtick-quoted tokens from an inline sentence.
    private static func quotedTokens(_ line: String) -> [String] {
        var tokens: [String] = []
        for quote: Character in ["\"", "`"] {
            var remainder = Substring(line)
            while let open = remainder.firstIndex(of: quote) {
                let afterOpen = remainder.index(after: open)
                guard let close = remainder[afterOpen...].firstIndex(of: quote) else { break }
                let token = String(remainder[afterOpen..<close]).trimmingCharacters(in: .whitespaces)
                if !token.isEmpty { tokens.append(token) }
                remainder = remainder[remainder.index(after: close)...]
            }
        }
        return tokens
    }

    // MARK: - Type inference

    private static func inferType(name: String, default def: String, enums: [String]) -> OptionValueType {
        if !enums.isEmpty { return .enumeration }
        let v = def.trimmingCharacters(in: .whitespaces)
        if v == "true" || v == "false" { return .boolean }
        if !v.isEmpty, Int(v) != nil || Double(v) != nil { return .number }
        if looksLikeColorOption(name: name, value: v) { return .color }
        return .unknown
    }

    private static func looksLikeColorOption(name: String, value: String) -> Bool {
        if value.hasPrefix("#") { return true }
        let n = name.lowercased()
        return n.contains("color") || n == "background" || n == "foreground"
    }
}
