import Foundation

/// One physical line of a config file, classified but byte-preserving.
///
/// `raw` is the exact original text (without its trailing line terminator).
/// Re-serializing every line's `raw` verbatim is what lets the writer (U6) touch
/// only edited lines and leave comments/blank/unknown lines untouched (R8, R11).
public struct ConfigLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case blank
        case comment
        case setting(key: String, value: String)
        /// Non-empty, not a comment, not a `key = value` line. Preserved verbatim.
        case unparsed
    }

    public let raw: String
    public let kind: Kind
    /// 1-based line number within its file.
    public let lineNumber: Int

    public var key: String? {
        if case .setting(let key, _) = kind { return key }
        return nil
    }

    public var value: String? {
        if case .setting(_, let value) = kind { return value }
        return nil
    }

    public init(raw: String, kind: Kind, lineNumber: Int) {
        self.raw = raw
        self.kind = kind
        self.lineNumber = lineNumber
    }

    /// Classify a raw line per Ghostty config syntax: `#`-prefixed comments
    /// (comment marker only at line start), blank lines, and `key = value`.
    /// A trailing `\r` (CRLF file) is stripped for classification but kept in `raw`.
    public static func classify(_ raw: String) -> Kind {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        if trimmed.hasPrefix("#") { return .comment }
        if let (key, value) = splitSetting(line) { return .setting(key: key, value: value) }
        return .unparsed
    }

    /// Split a `key = value` line on the first `=`. Preserves any further `=`
    /// in the value (e.g., `keybind = cmd+[=unbind`). Returns nil when the text
    /// before `=` is not a valid option name.
    public static func splitSetting(_ line: String) -> (key: String, value: String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" })
        else { return nil }
        var value = String(line[line.index(after: eq)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (key, value)
    }
}

/// A single parsed config file, line-preserving (KTD5).
public struct ConfigFile: Sendable, Equatable {
    /// The path as referenced (may be a symlink or a relative include).
    public let path: String
    /// The symlink-resolved canonical path (the real file the writer edits, R20).
    public let resolvedPath: String
    public var lines: [ConfigLine]
    /// "\n" or "\r\n", preserved for byte-exact round-trips (R23).
    public let lineEnding: String
    /// Whether the file ended with a trailing newline (R23).
    public let hasTrailingNewline: Bool
    /// Whether the file began with a UTF-8 BOM, re-emitted on serialize (R23).
    public let hasBOM: Bool
    /// On-disk identity captured at read time; nil for in-memory files. The
    /// writer uses this to detect external changes before overwriting (R22).
    public var identity: FileIdentity?

    public init(
        path: String,
        resolvedPath: String,
        lines: [ConfigLine],
        lineEnding: String,
        hasTrailingNewline: Bool,
        hasBOM: Bool = false,
        identity: FileIdentity? = nil
    ) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.lines = lines
        self.lineEnding = lineEnding
        self.hasTrailingNewline = hasTrailingNewline
        self.hasBOM = hasBOM
        self.identity = identity
    }

    private static let bom = "\u{FEFF}"

    /// Parse file text into classified lines, byte-preserving. Splits on `\n`
    /// universally and keeps any trailing `\r` inside each line's `raw`, so files
    /// with CRLF, LF, or *mixed* endings round-trip exactly and each physical
    /// line is classified independently (no setting is folded into another).
    public static func parse(text rawText: String, path: String, resolvedPath: String? = nil) -> ConfigFile {
        let hasBOM = rawText.hasPrefix(bom)
        var text = hasBOM ? String(rawText.dropFirst()) : rawText

        // Operate on the last unicode *scalar*, not the last Character: Swift
        // treats "\r\n" as a single grapheme, so `hasSuffix("\n")` is false for a
        // CRLF file and `removeLast()` would strip the whole CRLF. Scalars detect
        // (and strip just) the trailing "\n" for LF and CRLF alike.
        let hasTrailing = text.unicodeScalars.last == "\n"
        if hasTrailing { text.unicodeScalars.removeLast() }

        let rawLines = (text.isEmpty && !hasTrailing) ? [] : text.components(separatedBy: "\n")
        let lines = rawLines.enumerated().map { index, raw in
            ConfigLine(raw: raw, kind: ConfigLine.classify(raw), lineNumber: index + 1)
        }
        // Dominant ending is informational only (any line generated by the writer
        // uses LF); per-line terminators live in `raw`.
        let lineEnding = rawLines.contains { $0.hasSuffix("\r") } ? "\r\n" : "\n"
        return ConfigFile(
            path: path,
            resolvedPath: resolvedPath ?? path,
            lines: lines,
            lineEnding: lineEnding,
            hasTrailingNewline: hasTrailing,
            hasBOM: hasBOM
        )
    }

    /// Reconstruct the file's text exactly (for an unedited file this is the
    /// original bytes; the writer relies on this round-trip). Joins on `\n`;
    /// each line carries its own `\r` if it had one.
    public func serialized() -> String {
        var out = lines.map(\.raw).joined(separator: "\n")
        if hasTrailingNewline { out += "\n" }
        if hasBOM { out = Self.bom + out }
        return out
    }

    /// A copy with the line list replaced (used by the writer).
    public func replacingLines(_ newLines: [ConfigLine]) -> ConfigFile {
        ConfigFile(
            path: path,
            resolvedPath: resolvedPath,
            lines: newLines,
            lineEnding: lineEnding,
            hasTrailingNewline: hasTrailingNewline,
            hasBOM: hasBOM,
            identity: identity
        )
    }

    /// All setting lines for a key, in file order (additive keys yield many).
    public func settingLines(for key: String) -> [ConfigLine] {
        lines.filter { $0.key == key }
    }
}

/// Where a setting was defined — used by the merged view and the writer.
public struct SettingLocation: Sendable, Equatable, Hashable {
    public let file: String
    public let line: Int
    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }
}

/// The full line-preserving model: the primary config file plus any
/// `config-file` includes, in first-seen order (KTD5, R7).
public struct ConfigModel: Sendable {
    public var primary: ConfigFile
    /// Included files in first-encountered order.
    public var includes: [ConfigFile]

    public init(primary: ConfigFile, includes: [ConfigFile] = []) {
        self.primary = primary
        self.includes = includes
    }

    public var allFiles: [ConfigFile] { [primary] + includes }

    public func file(resolvedPath: String) -> ConfigFile? {
        allFiles.first { $0.resolvedPath == resolvedPath }
    }
}
