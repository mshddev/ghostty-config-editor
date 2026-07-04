import Foundation

/// Plain-language names and summaries for Ghostty's bindable actions (R1,
/// CONTENT-3, A11Y-4).
///
/// Ghostty names actions by their raw snake_case identifier (`copy_to_clipboard`,
/// `goto_split`). The Keybindings editor lists ~140 of them, so every action gets a
/// friendly `title` — curated when we have one, otherwise the humanized identifier —
/// and any `:param` is humanized separately so a parameterized action reads as
/// "Focus a split (previous)" rather than `goto_split:previous`.
///
/// Shares A1's humanizer: an action identifier is mapped from snake_case onto the
/// kebab-case form `LabelCatalog.humanize` already handles.
public struct ActionLabelCatalog: Sendable {

    public struct Label: Sendable, Codable, Equatable {
        public let title: String
        public let summary: String?

        public init(title: String, summary: String? = nil) {
            self.title = title
            self.summary = summary
        }
    }

    private let curated: [String: Label]

    public init(curated: [String: Label]) {
        self.curated = curated
    }

    /// Curated action names — used by the orphan-key guard (KTD1).
    public var curatedActionNames: Set<String> {
        Set(curated.keys)
    }

    // MARK: - Read API

    /// Friendly title for a param-less action name. Curated wins; otherwise the
    /// humanized identifier. Never empty (R1).
    public func displayTitle(forAction name: String) -> String {
        if let title = curated[name]?.title, !title.isEmpty { return title }
        return Self.humanizeActionName(name)
    }

    /// A one-line description for an action, or empty when none is curated.
    public func shortSummary(forAction name: String) -> String {
        curated[name]?.summary ?? ""
    }

    /// Full display title for a raw action string, appending a humanized `:param`
    /// when present. `goto_split:previous` → "Focus a split (previous)".
    public func displayTitle(for action: String) -> String {
        let base = displayTitle(forAction: Keybind.actionName(action))
        if let param = Self.actionParam(action) {
            return base + " " + Self.humanizeParam(param)
        }
        return base
    }

    /// Display title that folds the `:param` parenthetical into the title **only** when
    /// the base action carries more than one distinct param across the visible set
    /// (`foldParams`, from `multiParamActions(in:)`) — so `goto_tab:1…8` disambiguate as
    /// "Go to tab (1)…(8)", but `copy_to_clipboard:mixed`, the sole variant, reads simply
    /// as "Copy" with its param left to the caption/help (KB-4). An action with no param,
    /// or one not in `foldParams`, gets its base title alone.
    public func displayTitle(for action: String, foldingParamsFor foldParams: Set<String>) -> String {
        let base = Keybind.actionName(action)
        let baseTitle = displayTitle(forAction: base)
        guard let param = Self.actionParam(action), foldParams.contains(base) else { return baseTitle }
        return baseTitle + " " + Self.humanizeParam(param)
    }

    /// The set of base action names that carry more than one distinct `:param` across
    /// `actions` — the actions whose param is load-bearing enough to fold into the title
    /// (KB-4). Kept in the kit so the fold decision is unit-testable independent of the
    /// view. `goto_tab` (params 1…8) qualifies; `copy_to_clipboard` (only `mixed`) doesn't.
    public static func multiParamActions(in actions: [String]) -> Set<String> {
        var paramsByBase: [String: Set<String>] = [:]
        for action in actions {
            guard let param = actionParam(action) else { continue }
            paramsByBase[Keybind.actionName(action), default: []].insert(param)
        }
        return Set(paramsByBase.filter { $0.value.count > 1 }.keys)
    }

    // MARK: - Fallbacks

    /// The `:param` portion of an action, or nil when there is none.
    /// `goto_split:previous` → "previous"; `copy_to_clipboard` → nil.
    public static func actionParam(_ action: String) -> String? {
        let trimmed = action.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let param = String(trimmed[trimmed.index(after: colon)...])
        return param.isEmpty ? nil : param
    }

    /// Render a param as a parenthetical. Accepts the value with or without a
    /// leading colon: `:previous` → "(previous)"; `top_left` → "(top left)".
    public static func humanizeParam(_ param: String) -> String {
        var value = param
        if value.hasPrefix(":") { value.removeFirst() }
        let words = value.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? "" : "(\(words))"
    }

    /// Sentence-case an action identifier, reusing A1's humanizer by mapping
    /// snake_case onto its kebab-case input.
    public static func humanizeActionName(_ name: String) -> String {
        LabelCatalog.humanize(name.replacingOccurrences(of: "_", with: "-"))
    }

    // MARK: - Bundled resource

    private struct File: Codable { let labels: [String: Label] }

    public static func decode(_ data: Data) throws -> ActionLabelCatalog {
        ActionLabelCatalog(curated: try JSONDecoder().decode(File.self, from: data).labels)
    }

    public static let bundled: ActionLabelCatalog = {
        guard let url = Bundle.module.url(forResource: "action-labels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(data) else {
            return ActionLabelCatalog(curated: [:])
        }
        return catalog
    }()
}

public extension KeybindAction {
    /// Friendly name for this action, from the bundled `ActionLabelCatalog` (R1).
    var displayTitle: String { ActionLabelCatalog.bundled.displayTitle(forAction: name) }
}

public extension Keybind {
    /// Friendly name for this binding's action, including any humanized `:param`.
    var actionDisplayTitle: String { ActionLabelCatalog.bundled.displayTitle(for: action) }
}
