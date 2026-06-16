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

            guard let (key, value) = parseKeyValueLine(line) else {
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

    // MARK: - Line parsing

    /// Split a `key = value` line. The separator is the first `=`; the value is
    /// everything after it (with one leading separator space removed), preserving
    /// any further `=` characters (e.g., `keybind = super+,=open_config`).
    static func parseKeyValueLine(_ line: String) -> (key: String, value: String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, isValidOptionName(key) else { return nil }
        var value = String(line[line.index(after: eq)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (key, value)
    }

    private static func isValidOptionName(_ s: String) -> Bool {
        s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" }
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

    /// Pull enumerated values from a "Valid values are:" section: backtick-quoted
    /// tokens on bullet lines (`* \`block\``). Tolerant of a blank line between
    /// the sentinel and the bullets, and of per-bullet descriptions.
    static func extractEnumValues(_ documentation: String) -> [String] {
        var values: [String] = []
        var collecting = false
        for rawLine in documentation.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().contains("valid values are") {
                collecting = true
                continue
            }
            guard collecting else { continue }
            if line.hasPrefix("* ") || line.hasPrefix("- ") {
                if let token = firstBacktickToken(line) {
                    values.append(token)
                }
            }
            // Non-bullet lines (prose, blanks) are skipped, not terminators, so
            // wrapped bullet descriptions don't cut the list short.
        }
        // De-dup while preserving order.
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func firstBacktickToken(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "`") else { return nil }
        let afterOpen = line.index(after: open)
        guard let close = line[afterOpen...].firstIndex(of: "`") else { return nil }
        let token = String(line[afterOpen..<close])
        return token.isEmpty ? nil : token
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
