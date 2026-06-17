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
            let enums = extractEnumValues(b.documentation)
            let repeatable = b.defaultValues.count > 1 || knownRepeatableKeys.contains(name)
            return CatalogOption(
                name: b.name,
                defaultValues: b.defaultValues,
                documentation: b.documentation,
                category: OptionCategorizer.category(for: b.name),
                valueType: inferType(name: b.name, default: b.defaultValues.first ?? "", enums: enums),
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

    /// Pull enumerated values from a doc section. Handles both Ghostty doc styles:
    ///  - bulleted: "Valid values are:" followed by `* \`block\`` lines
    ///  - inline:   "Available values are: \"native\", \"transparent\", …"
    /// Tolerant of a blank line before the bullets and of per-bullet descriptions.
    static func extractEnumValues(_ documentation: String) -> [String] {
        enum Mode { case none, bulleted, inline }
        var values: [String] = []
        var mode: Mode = .none
        for rawLine in documentation.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.contains("valid values are") {
                mode = .bulleted
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
                // Skip blanks/prose (not terminators) so wrapped bullet
                // descriptions don't cut the list short.
                if line.hasPrefix("* ") || line.hasPrefix("- ") {
                    if let token = firstBacktickToken(line) { values.append(token) }
                }
            case .inline:
                if line.isEmpty { mode = .none } // paragraph break ends the inline list
                else { values.append(contentsOf: quotedTokens(line)) }
            }
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func firstBacktickToken(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "`") else { return nil }
        let afterOpen = line.index(after: open)
        guard let close = line[afterOpen...].firstIndex(of: "`") else { return nil }
        // Reject empty/whitespace-only tokens (e.g. a `* \` \` (blank)` bullet).
        let token = String(line[afterOpen..<close]).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
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
