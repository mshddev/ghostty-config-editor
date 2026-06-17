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

    public func option(named name: String) -> CatalogOption? {
        options.first { $0.name == name }
    }

    /// Categories in a stable, curated display order (known categories first,
    /// then any others alphabetically).
    public var categories: [String] {
        OptionCategorizer.orderedCategories(present: Set(options.map(\.category)))
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
        // No `desktop` prefix: `desktop-notifications` is cross-platform (kept on
        // macOS, categorized via a nameOverride below). Mapping `desktop-*` here
        // would miscategorize a future cross-platform desktop option as Linux/GTK.
        "app": "macOS",
        "quick": "macOS",
        "auto": "macOS",
    ]

    /// Exact-name overrides for options whose prefix would mis-categorize them.
    private static let nameOverrides: [String: String] = [
        "theme": "Colors & Theme",
        "bold-is-bright": "Colors & Theme",
        "tab-bar": "Tabs & Splits",
        // Kept on macOS (OSC 9/777 escape-sequence notifications work here), so it
        // must not land in the otherwise-empty "Linux / GTK" group via its
        // `desktop-` prefix. It's a terminal-protocol capability.
        "desktop-notifications": "Terminal",
    ]

    public static func category(for name: String) -> String {
        if let exact = nameOverrides[name] { return exact }
        let prefix = name.split(separator: "-").first.map(String.init) ?? name
        if let mapped = prefixMap[prefix.lowercased()] { return mapped }
        return "General"
    }

    /// Known categories first (in display order), then any extras alphabetically.
    public static func orderedCategories(present: Set<String>) -> [String] {
        var ordered = displayOrder.filter(present.contains)
        ordered.append(contentsOf: present.subtracting(ordered).sorted())
        return ordered
    }
}

/// macOS-scoping policy for the catalog — the "macOS-scoped catalog" decision in
/// `docs/brainstorms/2026-06-16-ghostty-config-manager-requirements.md` (R1, R6).
///
/// Ghostty's `+show-config` output is platform-agnostic and lists options that
/// only take effect on Linux/GTK/Wayland/X11. This app is macOS-only, so those
/// options are excluded from the catalog at parse time — they then never reach the
/// sidebar, search, All Options, or the "Not Using Yet" discovery surface, which
/// would otherwise recommend changes that do nothing on macOS.
///
/// The CLI carries no machine-readable platform tag, so membership is curated from
/// each option's own `--docs` platform-restriction language (verified against
/// Ghostty 1.3.x). Two rules combine:
///   1. Any `gtk-`/`x11-`/`linux-`/`wayland-`-prefixed option is Linux-stack-only.
///   2. A curated set of options that are doc-confirmed Linux/GTK/Wayland-only but
///      do *not* carry one of those prefixes (see `nonPrefixedLinuxOnly`).
///
/// Cross-platform options are kept even when their name looks platform-ish — most
/// notably `desktop-notifications`, whose OSC 9 / OSC 777 escape sequences work on
/// macOS. The prefix rule deliberately omits `desktop-` for that reason.
///
/// This is intentionally a hand-maintained list, revisited as Ghostty adds config
/// keys; a purely prefix-based filter is wrong at the edges in both directions
/// (it would drop `desktop-notifications` and miss `app-notifications`).
public enum MacOSCatalogScope {

    /// Name prefixes that unambiguously mark an option as part of the Linux display
    /// stack (GTK / X11 / Wayland / Linux cgroups). `desktop-` is intentionally
    /// absent — `desktop-notifications` is cross-platform.
    static let linuxStackPrefixes = ["gtk-", "x11-", "linux-", "wayland-"]

    /// Options that are doc-confirmed Linux/GTK/Wayland-only yet lack a Linux-stack
    /// prefix, so the prefix rule alone would miss them. Each is annotated with the
    /// `--docs` sentence that establishes it has no effect on macOS.
    static let nonPrefixedLinuxOnly: Set<String> = [
        "language",                              // "GTK only."
        "async-backend",                         // "only supported on Linux ... On macOS, we always use `kqueue`."
        "quit-after-last-window-closed-delay",   // "Only implemented on Linux."
        "window-show-tab-bar",                   // "Currently only supported on Linux (GTK)."
        "window-subtitle",                       // "This feature is only supported on GTK."
        "app-notifications",                     // "This configuration only applies to GTK."
        "quick-terminal-keyboard-interactivity", // "Only has an effect on Linux Wayland."
        "class",                                 // "This only affects GTK builds." (X11 WM_CLASS / Wayland app ID / DBus)
        "freetype-load-flags",                   // "macOS uses CoreText and does not have an equivalent configuration."
    ]

    /// True when an option never takes effect on macOS and should be excluded from
    /// the catalog this app presents.
    public static func excludes(_ name: String) -> Bool {
        if linuxStackPrefixes.contains(where: name.hasPrefix) { return true }
        return nonPrefixedLinuxOnly.contains(name)
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
