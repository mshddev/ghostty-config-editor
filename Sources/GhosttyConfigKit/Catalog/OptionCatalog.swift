import Foundation

/// Best-effort value type for a config option, inferred from its docs/default.
/// `unknown` is a first-class state — the catalog never guesses when the
/// doc text gives no signal.
public enum OptionValueType: String, Sendable, Hashable, Codable {
    case boolean
    case number
    case color
    case enumeration
    case string
    case unknown
}

public extension OptionValueType {
    /// A plain-language name for the kind of value, or `nil` for
    /// `.unknown` — the catalog never invents a type when the docs give no signal,
    /// so the UI shows nothing rather than guessing.
    var displayName: String? {
        switch self {
        case .boolean: return "On/off"
        case .number: return "Number"
        case .color: return "Color"
        case .enumeration: return "Choice"
        case .string: return "Text"
        case .unknown: return nil
        }
    }
}

/// One config option as described by the user's installed Ghostty.
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
    /// True when the key may appear multiple times in a config.
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
    /// When a change to this option takes effect, inferred from its docs.
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

    /// A human-facing notice for non-live changes, or nil when live.
    ///
    /// Worded **additively**, not correctively, so it reads complementarily when the
    /// app stacks it above the scope-neutral auto-reload caption: the reload
    /// caption says Ghostty was asked to reload, and this line clarifies that *this
    /// particular* option needs a new surface or a full restart on top of that — the
    /// two never contradict. (Tested not to begin with the old "This takes effect …".)
    var applyNotice: String? {
        switch changeScope {
        case .live: return nil
        case .newSurface: return "Affects new terminals — open a new window or tab to see it."
        case .restart: return "Needs a full Ghostty restart to take full effect."
        }
    }

    /// Plain-language name for this option, from the bundled `LabelCatalog`.
    /// Always non-empty — a curated title when we have one, otherwise
    /// the humanized raw key. The raw `name` stays searchable.
    var displayTitle: String { LabelCatalog.bundled.displayTitle(for: name) }

    /// A best-effort one-line description (curated summary → first doc sentence →
    /// empty). May be empty; the always-present `displayTitle` is the guaranteed label.
    var shortSummary: String { LabelCatalog.bundled.shortSummary(for: name, documentation: documentation) }

    /// The same summary without the tooltip-length char cap, for row subtitles that own
    /// their own visual truncation via `lineLimit(1...2)`. Lets a real sentence
    /// wrap to a second line instead of being ellipsized mid-word at 120 chars.
    var subtitleSummary: String {
        LabelCatalog.bundled.shortSummary(for: name, documentation: documentation, maxLength: .max)
    }

    /// Curated range/step/unit/style for a numeric option, or `nil` when none is
    /// specified (the editor then uses a plain number field).
    var numericSpec: NumericSpec? { NumericSpecCatalog.bundled.spec(for: name) }

    /// True when this option accepts `true`/`false` alongside other values, so the
    /// editor renders toggle-first. `valueType` is unchanged.
    var isBooleanish: Bool { CatalogParser.isBooleanish(name) }

    /// A friendly label for one of this option's enum values,
    /// falling back to the raw value when none is curated.
    func enumValueLabel(_ value: String) -> String {
        EnumValueLabels.bundled.label(option: name, value: value)
    }
}

/// The full set of options for a given Ghostty version.
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
        options.filter { $0.category == category }.sorted(by: OptionOrdering.compare)
    }
}

/// Maps option names to sidebar categories. Ghostty's `--docs` output has
/// no section headers, so categories are derived from the option name's prefix.
public enum OptionCategorizer {
    /// The one category name for keyboard shortcuts, shared by the categorizer, the
    /// sidebar icon map, the `mainColumn` router, and the editor's title, so a
    /// rename can't desync the routing that shows `KeybindEditorView`.
    public static let keybindingsCategory = "Keyboard Shortcuts"

    /// The catch-all for options with no clearer home — the true internals. Also the
    /// fallback for anything unmapped, so a new Ghostty option never resurfaces a
    /// phantom "General" bucket.
    public static let advancedCategory = "Advanced"

    /// The colors category. Shared so the Appearance→Themes cross-link tests for
    /// "am I on Appearance" against this constant rather than a bare string literal.
    public static let appearanceCategory = "Appearance"

    /// Preferred display order for the sidebar (newcomer-frequency order). "Themes"
    /// and the keyboard editor are dedicated surfaces routed separately; every other
    /// entry is an option-list category.
    public static let displayOrder: [String] = [
        "Appearance",
        "Font & Text",
        "Window",
        "Tabs & Splits",
        "Cursor",
        "Mouse & Scrolling",
        keybindingsCategory,
        "Clipboard",
        "Notifications & Bell",
        "Startup & Shell",
        "macOS",
        advancedCategory,
    ]

    /// First-segment prefix → category. Explicit `nameOverrides` win over this for
    /// options a prefix would mis-file. Linux-stack prefixes are intentionally
    /// absent — `MacOSCatalogScope` drops those options before categorization.
    private static let prefixMap: [String: String] = [
        // Font & Text
        "font": "Font & Text",
        "adjust": "Font & Text",
        "grapheme": "Font & Text",
        // Appearance
        "background": "Appearance",
        "foreground": "Appearance",
        "selection": "Appearance",
        "palette": "Appearance",
        "bold": "Appearance",
        "minimum": "Appearance",
        "alpha": "Appearance",
        "custom": "Appearance",   // custom-shader*
        "faint": "Appearance",
        "search": "Appearance",   // search-background/foreground colors
        // Tabs & Splits
        "split": "Tabs & Splits",
        "unfocused": "Tabs & Splits",
        "tab": "Tabs & Splits",
        // Cursor
        "cursor": "Cursor",
        // Mouse & Scrolling
        "mouse": "Mouse & Scrolling",
        "focus": "Mouse & Scrolling",
        "click": "Mouse & Scrolling",
        "scroll": "Mouse & Scrolling",
        "scrollback": "Mouse & Scrolling",
        "scrollbar": "Mouse & Scrolling",
        "right": "Mouse & Scrolling",   // right-click-action
        // Window
        "window": "Window",
        "title": "Window",
        "fullscreen": "Window",
        "maximize": "Window",
        "resize": "Window",
        // Clipboard
        "clipboard": "Clipboard",
        "copy": "Clipboard",
        "paste": "Clipboard",
        // Keyboard Shortcuts
        "keybind": keybindingsCategory,
        // Notifications & Bell
        "bell": "Notifications & Bell",
        "notify": "Notifications & Bell",
        // Startup & Shell
        "shell": "Startup & Shell",
        "command": "Startup & Shell",
        "env": "Startup & Shell",
        "working": "Startup & Shell",
        "wait": "Startup & Shell",
        "abnormal": "Startup & Shell",
        // macOS
        "macos": "macOS",
        "quick": "macOS",     // quick-terminal-*
        "auto": "macOS",      // auto-update*
        "app": "macOS",
    ]

    /// Exact-name overrides for options whose prefix would mis-categorize them.
    private static let nameOverrides: [String: String] = [
        // "theme" has no useful prefix mapping of its own; it's an Appearance choice
        // (also surfaced by the dedicated Themes browser).
        "theme": "Appearance",
        // The title bar is a window concern and a Window "common" setting, so keep it
        // out of the macOS bucket its prefix would send it to.
        "macos-titlebar-style": "Window",
        // Cross-platform (OSC 9/777), grouped with the other notification settings.
        "desktop-notifications": "Notifications & Bell",
        // Tab-related despite the `window-`/`initial-` prefixes.
        "window-new-tab-position": "Tabs & Splits",
        // Startup, not a generic window/command.
        "initial-command": "Startup & Shell",
        "initial-window": "Window",
        // Command-palette internals, not a startup command.
        "command-palette-entry": advancedCategory,
    ]

    public static func category(for name: String) -> String {
        if let exact = nameOverrides[name] { return exact }
        let prefix = name.split(separator: "-").first.map(String.init) ?? name
        if let mapped = prefixMap[prefix.lowercased()] { return mapped }
        // Unmapped options land in Advanced — never a phantom "General" bucket, so
        // `orderedCategories`' append-unknown step can't resurface one.
        return advancedCategory
    }

    /// Known categories first (in display order), then any extras alphabetically.
    public static func orderedCategories(present: Set<String>) -> [String] {
        var ordered = displayOrder.filter(present.contains)
        ordered.append(contentsOf: present.subtracting(ordered).sorted())
        return ordered
    }
}

/// macOS-scoping policy for the catalog.
///
/// Ghostty's `+show-config` output is platform-agnostic and lists options that
/// only take effect on Linux/GTK/Wayland/X11. This app is macOS-only, so those
/// options are excluded from the catalog at parse time — they then never reach the
/// sidebar, search, or any discovery surface, which would otherwise recommend
/// changes that do nothing on macOS.
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
    private static let linuxStackPrefixes: [String] = ["gtk-", "x11-", "linux-", "wayland-"]

    /// Options that are doc-confirmed Linux/GTK/Wayland-only yet lack a Linux-stack
    /// prefix, so the prefix rule alone would miss them. Each is annotated with the
    /// `--docs` sentence that establishes it has no effect on macOS.
    private static let nonPrefixedLinuxOnly: Set<String> = [
        "language",                              // "GTK only."
        "async-backend",                         // "only supported on Linux ... On macOS, we always use `kqueue`."
        "quit-after-last-window-closed-delay",   // "Only implemented on Linux."
        "window-show-tab-bar",                   // "Currently only supported on Linux (GTK)."
        "window-subtitle",                       // "This feature is only supported on GTK."
        "app-notifications",                     // "This configuration only applies to GTK."
        "quick-terminal-keyboard-interactivity", // "Only has an effect on Linux Wayland."
        "class",                                 // "This only affects GTK builds." (X11 WM_CLASS / Wayland app ID / DBus)
        "freetype-load-flags",                   // "macOS uses CoreText and does not have an equivalent configuration."
        "window-titlebar-background",            // "Currently only supported in the GTK app runtime."
        "window-titlebar-foreground",            // "Currently only supported in the GTK app runtime."
    ]

    /// True when an option never takes effect on macOS and should be excluded from
    /// the catalog this app presents.
    public static func excludes(_ name: String) -> Bool {
        if linuxStackPrefixes.contains(where: name.hasPrefix) { return true }
        return nonPrefixedLinuxOnly.contains(name)
    }
}

/// Loads and caches the option catalog, keyed by binary version. When the
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
