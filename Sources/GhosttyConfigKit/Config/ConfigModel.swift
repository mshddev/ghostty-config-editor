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
    public static func classify(_ raw: String) -> Kind {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        if trimmed.hasPrefix("#") { return .comment }
        if let (key, value) = splitSetting(raw) { return .setting(key: key, value: value) }
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
    /// The symlink-resolved canonical path (the inode the writer must edit, R20).
    public let resolvedPath: String
    public var lines: [ConfigLine]
    /// "\n" or "\r\n", preserved for byte-exact round-trips (R23).
    public let lineEnding: String
    /// Whether the file ended with a trailing newline (R23).
    public let hasTrailingNewline: Bool

    public init(path: String, resolvedPath: String, lines: [ConfigLine], lineEnding: String, hasTrailingNewline: Bool) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.lines = lines
        self.lineEnding = lineEnding
        self.hasTrailingNewline = hasTrailingNewline
    }

    /// Parse file text into classified lines, detecting the line ending and
    /// trailing-newline state so the result can be re-emitted byte-for-byte.
    public static func parse(text: String, path: String, resolvedPath: String? = nil) -> ConfigFile {
        let lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        let hasTrailing = text.hasSuffix(lineEnding) || (lineEnding == "\n" && text.hasSuffix("\n"))

        var body = text
        if hasTrailing { body.removeLast(lineEnding.count) }

        let rawLines = body.isEmpty && !hasTrailing
            ? []
            : body.components(separatedBy: lineEnding)

        let lines = rawLines.enumerated().map { index, raw in
            ConfigLine(raw: raw, kind: ConfigLine.classify(raw), lineNumber: index + 1)
        }
        return ConfigFile(
            path: path,
            resolvedPath: resolvedPath ?? path,
            lines: lines,
            lineEnding: lineEnding,
            hasTrailingNewline: hasTrailing
        )
    }

    /// Reconstruct the file's text exactly (for an unedited file this is the
    /// original bytes; the writer relies on this round-trip).
    public func serialized() -> String {
        var out = lines.map(\.raw).joined(separator: lineEnding)
        if hasTrailingNewline { out += lineEnding }
        return out
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
