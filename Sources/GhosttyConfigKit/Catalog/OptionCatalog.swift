import Foundation

/// Best-effort value type for a config option, inferred from its docs/default
/// (R2). `unknown` is a first-class state — the catalog never guesses when the
/// doc text gives no signal.
public enum OptionValueType: String, Sendable, Hashable, Codable {
    case boolean
    case number
    case color
    case enumeration
    case string
    case unknown
}

/// One config option as described by the user's installed Ghostty (R1, R2).
public struct CatalogOption: Sendable, Hashable, Identifiable, Codable {
    public var id: String { name }
    public let name: String
    /// Default value(s). Scalars have one; repeatable keys (`keybind`, `palette`)
    /// may have many.
    public let defaultValues: [String]
    public let documentation: String
    public let category: String
    public let valueType: OptionValueType
    /// Enumerated values parsed from a "Valid values are:" doc section.
    public let enumValues: [String]
    /// True when the key may appear multiple times in a config (R9).
    public let isRepeatable: Bool

    public var defaultValue: String { defaultValues.first ?? "" }

    public init(
        name: String,
        defaultValues: [String],
        documentation: String,
        category: String,
        valueType: OptionValueType,
        enumValues: [String],
        isRepeatable: Bool
    ) {
        self.name = name
        self.defaultValues = defaultValues
        self.documentation = documentation
        self.category = category
        self.valueType = valueType
        self.enumValues = enumValues
        self.isRepeatable = isRepeatable
    }
}

public extension CatalogOption {
    /// When a change to this option takes effect, inferred from its docs (R17).
    enum ChangeScope: String, Sendable, Equatable {
        case live        // applies immediately on reload
        case newSurface  // only applies to new terminals/windows/tabs
        case restart     // requires fully restarting Ghostty
    }

    var changeScope: ChangeScope {
        let d = documentation.lowercased()
        if d.contains("requires restart") || d.contains("requires restarting")
            || d.contains("fully restart") || d.contains("full restart")
            || d.contains("full application restart") {
            return .restart
        }
        if d.contains("only applies to new") || d.contains("new windows")
            || d.contains("new surface") || d.contains("new terminal")
            || d.contains("only takes effect for new") {
            return .newSurface
        }
        return .live
    }

    /// A human-facing notice for non-live changes (AE5), or nil when live.
    var applyNotice: String? {
        switch changeScope {
        case .live: return nil
        case .newSurface: return "This affects new terminals, not the current session."
        case .restart: return "This takes effect after you fully restart Ghostty."
        }
    }
}

/// The full set of options for a given Ghostty version (R1).
public struct OptionCatalog: Sendable, Codable {
    public let options: [CatalogOption]
    /// The binary version this catalog was generated for (cache key).
    public let version: String?

    public init(options: [CatalogOption], version: String?) {
        self.options = options
        self.version = version
    }

    private var index: [String: CatalogOption] {
        Dictionary(options.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func option(named name: String) -> CatalogOption? {
        options.first { $0.name == name }
    }

    /// Categories in a stable, curated display order (known categories first,
    /// then any others alphabetically).
    public var categories: [String] {
        let present = Set(options.map(\.category))
        var ordered = OptionCategorizer.displayOrder.filter(present.contains)
        let extras = present.subtracting(ordered).sorted()
        ordered.append(contentsOf: extras)
        return ordered
    }

    public func options(in category: String) -> [CatalogOption] {
        options.filter { $0.category == category }.sorted { $0.name < $1.name }
    }
}

/// Maps option names to sidebar categories (R3). Ghostty's `--docs` output has
/// no section headers, so categories are derived from the option name's prefix.
public enum OptionCategorizer {
    /// Preferred display order for the sidebar.
    public static let displayOrder: [String] = [
        "Font",
        "Colors & Theme",
        "Cursor",
        "Mouse",
        "Window",
        "Tabs & Splits",
        "Clipboard",
        "Keybindings",
        "Shell Integration",
        "Terminal",
        "macOS",
        "Linux / GTK",
        "General",
    ]

    /// First-segment prefix → category. Longest/most-specific intent wins via
    /// the explicit name checks before the prefix map.
    private static let prefixMap: [String: String] = [
        "font": "Font",
        "adjust": "Font",
        "grapheme": "Font",
        "palette": "Colors & Theme",
        "theme": "Colors & Theme",
        "background": "Colors & Theme",
        "foreground": "Colors & Theme",
        "selection": "Colors & Theme",
        "bold": "Colors & Theme",
        "minimum": "Colors & Theme",
        "split": "Tabs & Splits",
        "unfocused": "Tabs & Splits",
        "cursor": "Cursor",
        "mouse": "Mouse",
        "focus": "Mouse",
        "click": "Mouse",
        "window": "Window",
        "fullscreen": "Window",
        "maximize": "Window",
        "resize": "Window",
        "clipboard": "Clipboard",
        "copy": "Clipboard",
        "paste": "Clipboard",
        "keybind": "Keybindings",
        "shell": "Shell Integration",
        "scrollback": "Terminal",
        "scroll": "Terminal",
        "term": "Terminal",
        "title": "Window",
        "macos": "macOS",
        "gtk": "Linux / GTK",
        "linux": "Linux / GTK",
        "x11": "Linux / GTK",
        "wayland": "Linux / GTK",
        "desktop": "Linux / GTK",
        "app": "macOS",
        "quick": "macOS",
        "auto": "macOS",
    ]

    /// Exact-name overrides for options whose prefix would mis-categorize them.
    private static let nameOverrides: [String: String] = [
        "theme": "Colors & Theme",
        "bold-is-bright": "Colors & Theme",
        "tab-bar": "Tabs & Splits",
    ]

    public static func category(for name: String) -> String {
        if let exact = nameOverrides[name] { return exact }
        let prefix = name.split(separator: "-").first.map(String.init) ?? name
        if let mapped = prefixMap[prefix.lowercased()] { return mapped }
        return "General"
    }
}

/// Loads and caches the option catalog, keyed by binary version (R1). When the
/// detected version changes, the cached catalog is invalidated and regenerated.
public actor CatalogProvider {
    private var cache: [String: OptionCatalog] = [:]
    private let load: @Sendable (String) async throws -> String

    /// - Parameter load: produces the raw `+show-config --default --docs` text
    ///   for a given version. The version argument lets callers vary output by
    ///   version; the live loader ignores it and always queries the binary.
    public init(load: @escaping @Sendable (String) async throws -> String) {
        self.load = load
    }

    public func catalog(forVersion version: String) async throws -> OptionCatalog {
        if let cached = cache[version] { return cached }
        let raw = try await load(version)
        let parsed = CatalogParser.parse(raw, version: version)
        cache[version] = parsed
        return parsed
    }

    /// Live provider backed by a discovered Ghostty installation.
    public static func live(_ environment: GhosttyEnvironment) -> CatalogProvider {
        let cli = environment.cli
        return CatalogProvider { _ in
            let result = try await cli.run(["+show-config", "--default", "--docs"])
            guard result.succeeded else {
                throw GhosttyCLIError.launchFailed(result.stderrString)
            }
            return result.stdoutString
        }
    }
}
