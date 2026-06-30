import Foundation

/// One of Ghostty's *default* keybinds, as listed by `+list-keybinds --default`.
/// Used only as the discover-and-override reference set — never as the source of
/// truth for the user's own bindings, which we parse prefix-preserving from the
/// config model (KTD3).
public struct DefaultKeybind: Sendable, Equatable, Identifiable {
    public var id: String { trigger }
    public let trigger: String
    public let action: String

    public init(trigger: String, action: String) {
        self.trigger = trigger
        self.action = action
    }

    /// The trigger normalized for matching against a user binding (KTD4).
    public var canonicalTrigger: String { KeybindTrigger.parse(trigger).canonical() }
    /// The action name without `:params`.
    public var actionName: String { Keybind.actionName(action) }
}

/// One of Ghostty's bindable actions, as listed by `+list-actions` (RK2).
public struct KeybindAction: Sendable, Equatable, Identifiable, Comparable {
    public var id: String { name }
    public let name: String

    public init(name: String) { self.name = name }

    public static func < (lhs: KeybindAction, rhs: KeybindAction) -> Bool { lhs.name < rhs.name }
}

/// Parses `+list-keybinds --default` and `+list-actions` output (RK1, RK2).
public enum KeybindReference {

    /// Parse `+list-keybinds --default --plain`: each line is `keybind = TRIGGER=ACTION`.
    /// Reuses U2's action-set-aware value parser so `=`/`+` keys split correctly.
    /// Parses whatever lines are present — no count or `--default`⊆effective
    /// assumption (Risk R-B). Non-`keybind` lines and whole-value specials are skipped.
    public static func parseDefaults(_ output: String, knownActions: Set<String> = []) -> [DefaultKeybind] {
        var defaults: [DefaultKeybind] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let (key, value) = ConfigLine.splitSetting(line), key == "keybind" else { continue }
            guard case .binding(let bind) = Keybind.parse(value: value, knownActions: knownActions),
                  !bind.actionName.isEmpty else { continue }
            defaults.append(DefaultKeybind(trigger: bind.trigger, action: bind.action))
        }
        return defaults
    }

    /// Parse `+list-actions`: one bare snake_case action name per line. Blank lines
    /// are dropped and duplicates collapsed; the first whitespace token of each line
    /// is taken so an accidental `--docs` description column can't leak in.
    public static func parseActions(_ output: String) -> [KeybindAction] {
        var actions: [KeybindAction] = []
        var seen = Set<String>()
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            // First whitespace-delimited token (any whitespace, incl. tabs) so an
            // accidental `--docs` description column can't leak into the name.
            guard let name = String(rawLine).split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
                  !name.isEmpty else { continue }
            if seen.insert(name).inserted { actions.append(KeybindAction(name: name)) }
        }
        return actions
    }
}

/// Loads and caches Ghostty's default keybinds + action list from the live binary,
/// mirroring `ThemeProvider`/`CatalogProvider` (KTD2: reuse `GhosttyCLI`, never
/// spawn a fresh `Process`).
public actor KeybindReferenceProvider {
    private let loadDefaults: @Sendable () async throws -> String
    private let loadActions: @Sendable () async throws -> String

    private var cachedDefaults: [DefaultKeybind]?
    private var cachedActions: [KeybindAction]?

    public init(
        loadDefaults: @escaping @Sendable () async throws -> String,
        loadActions: @escaping @Sendable () async throws -> String
    ) {
        self.loadDefaults = loadDefaults
        self.loadActions = loadActions
    }

    public func actions() async throws -> [KeybindAction] {
        if let cachedActions { return cachedActions }
        let parsed = KeybindReference.parseActions(try await loadActions())
        cachedActions = parsed
        return parsed
    }

    public func defaults() async throws -> [DefaultKeybind] {
        if let cachedDefaults { return cachedDefaults }
        // Parse the action list first so the default parser resolves the
        // `TRIGGER=ACTION` boundary precisely rather than via the shape heuristic.
        // A failure to list actions is non-fatal — fall back to the heuristic.
        let actionSet = Set(((try? await actions()) ?? []).map(\.name))
        let parsed = KeybindReference.parseDefaults(try await loadDefaults(), knownActions: actionSet)
        cachedDefaults = parsed
        return parsed
    }

    /// Live provider backed by a discovered Ghostty installation.
    public static func live(_ environment: GhosttyEnvironment) -> KeybindReferenceProvider {
        let cli = environment.cli
        return KeybindReferenceProvider(
            loadDefaults: {
                let result = try await cli.run(["+list-keybinds", "--default", "--plain"])
                guard result.succeeded else { throw GhosttyCLIError.launchFailed(result.stderrString) }
                return result.stdoutString
            },
            loadActions: {
                let result = try await cli.run(["+list-actions"])
                guard result.succeeded else { throw GhosttyCLIError.launchFailed(result.stderrString) }
                return result.stdoutString
            }
        )
    }
}
