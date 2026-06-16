import Foundation

/// A theme as listed by `+list-themes --path`.
public struct ThemeRef: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let source: String   // "resources" or "user"
    public let path: String

    public init(name: String, source: String, path: String) {
        self.name = name
        self.source = source
        self.path = path
    }
}

/// The colors a theme file defines (R12). `palette` covers indices 0–15.
public struct ThemeColors: Sendable, Equatable {
    public var palette: [Int: String]
    public var background: String?
    public var foreground: String?
    public var cursorColor: String?
    public var cursorText: String?
    public var selectionBackground: String?
    public var selectionForeground: String?

    public init(
        palette: [Int: String] = [:],
        background: String? = nil,
        foreground: String? = nil,
        cursorColor: String? = nil,
        cursorText: String? = nil,
        selectionBackground: String? = nil,
        selectionForeground: String? = nil
    ) {
        self.palette = palette
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
    }

    /// Palette entries 0–15 in order, for swatch rendering (missing ones omitted).
    public var orderedPalette: [String] {
        (0...15).compactMap { palette[$0] }
    }
}

/// How a `theme = …` value selects a theme (R12 supports light/dark).
public enum ThemeSelection: Sendable, Equatable {
    case single(String)
    case lightDark(light: String, dark: String)
}

public enum ThemeError: Error, Equatable, Sendable {
    case unreadable(String)
}

/// Parses Ghostty's theme + font listings and theme files. Note: `+list-themes`
/// emits only *names*, never colors — colors must be read from each theme's file
/// (resolved via `--path`), which is what this parser does.
public enum ThemeParser {

    /// Parse `+list-themes --path --plain`: lines of `Name (source) /abs/path`.
    public static func parseThemeList(_ output: String) -> [ThemeRef] {
        let regex = try? NSRegularExpression(pattern: #"^(.*) \((resources|user)\) (/.*)$"#)
        var refs: [ThemeRef] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let regex, let match = regex.firstMatch(in: line, range: range),
               let nameR = Range(match.range(at: 1), in: line),
               let srcR = Range(match.range(at: 2), in: line),
               let pathR = Range(match.range(at: 3), in: line) {
                refs.append(ThemeRef(
                    name: String(line[nameR]).trimmingCharacters(in: .whitespaces),
                    source: String(line[srcR]),
                    path: String(line[pathR])
                ))
            }
        }
        return refs
    }

    /// Parse a theme file into its colors. Theme files are `key = value` config
    /// fragments (`palette = 0=#hex`, `background = #hex`, …).
    public static func parseThemeFile(_ text: String) -> ThemeColors {
        var colors = ThemeColors()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (key, value) = ConfigLine.splitSetting(String(rawLine)) else { continue }
            let v = value.trimmingCharacters(in: .whitespaces)
            switch key {
            case "palette":
                // value is `index=#hex`
                if let eq = v.firstIndex(of: "="), let index = Int(v[v.startIndex..<eq]) {
                    colors.palette[index] = String(v[v.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                }
            case "background": colors.background = v
            case "foreground": colors.foreground = v
            case "cursor-color": colors.cursorColor = v
            case "cursor-text": colors.cursorText = v
            case "selection-background": colors.selectionBackground = v
            case "selection-foreground": colors.selectionForeground = v
            default: break
            }
        }
        return colors
    }

    /// Parse a `theme = …` value into a single or light/dark selection. The
    /// light/dark form is `light:Name,dark:Name` (order-independent).
    public static func parseThemeSetting(_ value: String) -> ThemeSelection {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().contains("light:") || trimmed.lowercased().contains("dark:") else {
            return .single(trimmed)
        }
        var light: String?
        var dark: String?
        for part in trimmed.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if let colon = piece.firstIndex(of: ":") {
                let key = piece[piece.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let name = String(piece[piece.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if key == "light" { light = name }
                if key == "dark" { dark = name }
            }
        }
        if let light, let dark { return .lightDark(light: light, dark: dark) }
        return .single(trimmed)
    }

    /// Serialize a selection back to a `theme` value.
    public static func serialize(_ selection: ThemeSelection) -> String {
        switch selection {
        case .single(let name): return name
        case .lightDark(let light, let dark): return "light:\(light),dark:\(dark)"
        }
    }

    /// Parse `+list-fonts` into family names (non-indented, non-blank lines).
    public static func parseFontList(_ output: String) -> [String] {
        var families: [String] = []
        var seen = Set<String>()
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            let name = line.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, seen.insert(name).inserted { families.append(name) }
        }
        return families
    }

    /// Honest preview-fidelity disclaimer (R14).
    public static let previewFidelityDisclaimer =
        "Color previews are faithful. Font rendering, ligatures, blur, and cursor effects are best-effort approximations — the real look only appears in Ghostty."
}

/// Lists themes and fonts from the live binary and lazily loads theme colors,
/// caching by theme path (R12).
public actor ThemeProvider {
    private let loadList: @Sendable () async throws -> String
    private let loadFontList: @Sendable () async throws -> String
    private let loadFile: @Sendable (String) throws -> String

    private var cachedThemes: [ThemeRef]?
    private var cachedFonts: [String]?
    private var colorCache: [String: ThemeColors] = [:]

    public init(
        loadList: @escaping @Sendable () async throws -> String,
        loadFontList: @escaping @Sendable () async throws -> String,
        loadFile: @escaping @Sendable (String) throws -> String
    ) {
        self.loadList = loadList
        self.loadFontList = loadFontList
        self.loadFile = loadFile
    }

    public func themes() async throws -> [ThemeRef] {
        if let cachedThemes { return cachedThemes }
        let parsed = ThemeParser.parseThemeList(try await loadList())
        cachedThemes = parsed
        return parsed
    }

    public func fonts() async throws -> [String] {
        if let cachedFonts { return cachedFonts }
        let parsed = ThemeParser.parseFontList(try await loadFontList())
        cachedFonts = parsed
        return parsed
    }

    public func colors(for theme: ThemeRef) throws -> ThemeColors {
        if let cached = colorCache[theme.path] { return cached }
        let parsed = ThemeParser.parseThemeFile(try loadFile(theme.path))
        colorCache[theme.path] = parsed
        return parsed
    }

    public static func live(_ environment: GhosttyEnvironment) -> ThemeProvider {
        let cli = environment.cli
        return ThemeProvider(
            loadList: { try await cli.run(["+list-themes", "--path", "--plain"]).stdoutString },
            loadFontList: { try await cli.run(["+list-fonts"]).stdoutString },
            loadFile: { path in
                guard let data = FileManager.default.contents(atPath: path) else {
                    throw ThemeError.unreadable(path)
                }
                return String(decoding: data, as: UTF8.self)
            }
        )
    }
}
