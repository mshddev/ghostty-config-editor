import Foundation
import Observation
import AppKit
import GhosttyConfigKit

/// What the sidebar can select.
///
/// `.themes` is the launch default (the first sidebar row); `.customized` and
/// `.problems` are entered from the top bar rather than a sidebar row; the rest
/// map to visible rows. A `nil` selection is a defensive fallback that shows the
/// unfiltered option list.
public enum SidebarSelection: Hashable {
    case customized
    case problems
    case themes
    case category(String)
}

/// Root application state (KTD9: `@Observable`, macOS 14+).
///
/// Owns the discovered Ghostty environment, the loaded catalog + merged config,
/// and the browser selection/search state the SwiftUI shell renders.
@MainActor
@Observable
public final class AppModel {

    public enum EnvironmentState {
        case loading
        case ready(GhosttyEnvironment)
        case notFound
        case unsupported(String)
    }

    public enum ContentState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Lifecycle of an in-flight apply (R17).
    public enum ApplyState: Equatable {
        case idle
        case applying
        /// Saved successfully. `notice` carries a new-surface/restart hint (AE5);
        /// `gitTracked` is true when the file lives in a git working tree (U7);
        /// `reload` is the auto-reload outcome whose kit-derived caption the views
        /// stack beneath the notice (R1, R6 — see `GhosttyReloader`).
        case succeeded(notice: String?, gitTracked: Bool, reload: ReloadOutcome)
        case failed(String)
    }

    public private(set) var environmentState: EnvironmentState = .loading
    public private(set) var contentState: ContentState = .idle
    public private(set) var browser: CatalogBrowser?
    /// Validation + footgun report for the loaded config (R15, R16).
    public private(set) var lintReport: LintReport?
    /// True when no config file exists yet — discovery still works against an
    /// all-unset view (R6, first-launch state).
    public private(set) var configMissing = false
    public private(set) var applyState: ApplyState = .idle
    /// Which option the current `applyState` describes. Editing is now inline in
    /// the list, so a single global `applyState` needs an anchor — each row shows
    /// feedback only while this matches its own name (the detail pane that owned
    /// the state unambiguously is gone).
    public private(set) var applyingOptionName: String?

    public var binaryOverride: String?
    public var selection: SidebarSelection? = .themes
    public var query: String = ""
    /// The Themes surface's own search text (name filter), bound to the shared
    /// `SurfaceHeader` field. Distinct from `query` so each surface filters itself
    /// and never means two things at once (C3). E1 layers light/dark grouping on top.
    public var themeQuery: String = ""
    public var selectedOptionName: String?

    /// `UserDefaults` key for the auto-reload toggle (KTD7).
    static let autoReloadDefaultsKey = "autoReloadEnabled"

    /// Whether a successful in-app write auto-reloads the running Ghostty (R7, KTD7).
    /// **On by default**; the toggle persists across launches. This is the app's first
    /// persisted setting — `binaryOverride`/`selection`/`query` are in-memory only, so
    /// they are not a persistence precedent. Stored (not computed) so a mid-session
    /// toggle updates the in-memory value immediately while `didSet` mirrors it to
    /// `UserDefaults`; the `Settings` toggle binds to this property, never to a bare
    /// `@AppStorage` that would leave this stored value stale (U3).
    public var autoReloadEnabled: Bool {
        didSet { UserDefaults.standard.set(autoReloadEnabled, forKey: Self.autoReloadDefaultsKey) }
    }

    /// `UserDefaults` key for the starred themes (E4).
    static let favoriteThemesDefaultsKey = "favoriteThemes"

    /// Themes the user has starred (E4), persisted across launches like
    /// `autoReloadEnabled`. Stored as a `Set` for O(1) membership in `isFavorite`;
    /// `didSet` mirrors it to `UserDefaults` as a string array (the value read back
    /// in `init`). Assigning in `init` does not fire `didSet`, so the initial load
    /// doesn't write straight back.
    public private(set) var favoriteThemes: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(favoriteThemes), forKey: Self.favoriteThemesDefaultsKey)
        }
    }

    private var environment: GhosttyEnvironment?
    private var catalog: OptionCatalog?
    private var lastReceipt: WriteReceipt?

    /// Signals the running Ghostty to reload after a successful write (R1). The kit
    /// owns the whole decision + safety policy; the app supplies only the AppKit
    /// instance enumeration (KTD3) — so this is `.live` with the app-side lister.
    private let reloader = GhosttyReloader.live(runningInstances: GhosttyInstanceLister.runningInstances)

    // Themes (U8)
    private var themeProvider: ThemeProvider?
    /// In-flight per-theme color loads, kept so they can be cancelled when the
    /// environment is reloaded (rather than leaking and writing into stale state).
    private var colorTasks: [String: Task<Void, Never>] = [:]
    private var failedThemes: Set<String> = []
    public private(set) var themes: [ThemeRef] = []
    public private(set) var themeColors: [String: ThemeColors] = [:]
    public private(set) var fonts: [String] = []

    // Keybindings (U5)
    private var keybindReference: KeybindReferenceProvider?
    public private(set) var keybindDefaults: [DefaultKeybind] = []
    public private(set) var keybindActions: [KeybindAction] = []

    public init() {
        // Default ON (KTD7): register the default so a fresh install reads `true`.
        // A bare `bool(forKey:)` returns `false` for a missing key, which would ship
        // auto-reload OFF and silently violate R7/AE8 — so the default is registered,
        // not assumed. (Assigning in `init` does not trigger the `didSet` above.)
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.autoReloadDefaultsKey: true])
        autoReloadEnabled = defaults.bool(forKey: Self.autoReloadDefaultsKey)
        // Favorites start empty (no key registered) and load from any prior session.
        favoriteThemes = Set(defaults.stringArray(forKey: Self.favoriteThemesDefaultsKey) ?? [])
    }

    public var canUndo: Bool { lastReceipt?.previousText != nil }

    /// Locate Ghostty, then load the catalog and merge the user's config.
    public func bootstrap() async {
        // A re-bootstrap (e.g. binary-override change) abandons stale theme/color
        // loads and clears caches so themes reload against the new environment.
        cancelInFlightColorLoads()
        themeProvider = nil
        themes = []
        themeColors = [:]
        fonts = []
        failedThemes = []
        keybindReference = nil
        keybindDefaults = []
        keybindActions = []
        environmentState = .loading
        contentState = .idle
        do {
            let environment = try await GhosttyEnvironment.discover(userOverride: binaryOverride)
            self.environment = environment
            environmentState = .ready(environment)
            await loadContent(environment)
        } catch GhosttyCLIError.binaryNotFound {
            environmentState = .notFound
        } catch GhosttyCLIError.versionUnverified(let output) {
            environmentState = .unsupported(output.isEmpty ? "unknown" : output)
        } catch {
            environmentState = .unsupported(error.localizedDescription)
        }
    }

    private func loadContent(_ environment: GhosttyEnvironment) async {
        contentState = .loading
        do {
            let provider = CatalogProvider.live(environment)
            let catalog = try await provider.catalog(forVersion: environment.version)
            self.catalog = catalog
            await refreshConfig(environment: environment, catalog: catalog)
            contentState = .loaded
        } catch {
            contentState = .failed(error.localizedDescription)
        }
    }

    /// Re-read the config from disk, rebuild the browser, and re-run validation.
    /// Used on first load and after every apply/undo so the UI reflects disk.
    private func refreshConfig(environment: GhosttyEnvironment, catalog: OptionCatalog) async {
        let reader = ConfigReader()
        let merged: MergedConfig
        do {
            merged = try reader.read(catalog: catalog)
            configMissing = false
        } catch {
            // No readable config yet: present an all-unset view, but point the
            // empty model at the real primary path so a first edit creates the
            // file in the right place (R6, first-launch state).
            merged = reader.merge(model: Self.emptyModel(), catalog: catalog)
            configMissing = true
        }
        if !configMissing {
            // Crash recovery: clear any temp left by a prior interrupted write.
            ConfigWriter().sweepStaleTempFiles(inDirectoryOf: merged.model.primary.resolvedPath)
        }
        browser = CatalogBrowser(merged: merged, catalog: catalog)
        lintReport = await ConfigLinter().analyze(
            model: merged.model,
            cli: configMissing ? nil : environment.cli
        )
    }

    /// An empty config model targeting the real primary config path, so a
    /// first-ever write lands at `~/.config/ghostty/config`.
    private static func emptyModel() -> ConfigModel {
        let path = ConfigReader.configDirectory()
            .appendingPathComponent(ConfigReader.candidateFilenames.first ?? "config").path
        return ConfigModel(primary: ConfigFile.parse(text: "", path: path, resolvedPath: ConfigReader.canonicalPath(path)))
    }

    // MARK: - Apply (U7)

    /// Validate a proposed change against the live binary, write it safely (U6),
    /// then reload so the UI reflects disk. Surfaces explicit feedback (R17).
    public func applyEdit(option: MergedOption, values: [String]) async {
        guard let environment, let browser else { return }
        applyingOptionName = option.option.name
        applyState = .applying
        let writer = ConfigWriter()
        do {
            let receipt = try await writer.validateAndApply(
                optionName: option.option.name,
                values: values,
                isRepeatable: option.option.isRepeatable,
                in: browser.merged.model,
                cli: environment.cli
            )
            lastReceipt = receipt
            let gitTracked = GitContext.isInsideWorkingTree(path: receipt.resolvedPath)
            if let catalog { await refreshConfig(environment: environment, catalog: catalog) }
            // Best-effort: ask the running Ghostty to reload now that the new bytes are
            // committed (R1). Never throws — the only throwing call here is the write
            // above — and never downgrades a successful save to a failure (R5/KTD5).
            let reload = reloader.reload(enabled: autoReloadEnabled)
            applyState = .succeeded(notice: option.option.applyNotice, gitTracked: gitTracked, reload: reload)
        } catch ConfigWriteError.validationFailed(let messages) {
            applyState = .failed(messages.first?.message ?? "The change didn't validate.")
        } catch ConfigWriteError.staleOnDisk {
            applyState = .failed("This file changed on disk since it was read. Reload and try again.")
        } catch ConfigWriteError.invalidValue {
            applyState = .failed("That value can't contain a line break.")
        } catch {
            applyState = .failed(error.localizedDescription)
        }
    }

    /// Revert the last applied write (R10).
    public func undoLastApply() async {
        guard let environment, let catalog, let receipt = lastReceipt else { return }
        applyState = .applying
        do {
            _ = try ConfigWriter().restore(from: receipt)
            lastReceipt = nil
            await refreshConfig(environment: environment, catalog: catalog)
            // Reload after an undo too, so the live terminal reverts (closes the undo
            // gap — undo previously refreshed only the app's own view) (R1/AE5).
            let reload = reloader.reload(enabled: autoReloadEnabled)
            applyState = .succeeded(notice: "Reverted to the previous value.", gitTracked: false, reload: reload)
        } catch {
            applyState = .failed(error.localizedDescription)
        }
    }

    public func resetApplyState() {
        applyState = .idle
        applyingOptionName = nil
    }

    // MARK: - Navigation & global Find (D)

    /// Bumped on each `focus(optionNamed:)` so a *mounted* option list can react to an
    /// explicit focus — never to ordinary sidebar navigation (which would otherwise
    /// chase a stale `selectedOptionName`).
    public private(set) var focusRequestID: Int = 0

    /// Set by `focus(optionNamed:)`, cleared once the option list scrolls the target
    /// into view. Unlike `focusRequestID`'s `onChange`, this flag survives the option
    /// list *remounting* — the common case, since a focus from a global Find result
    /// swaps the Find overlay out and the option list in, so `onChange` never fires and
    /// only an `onAppear` that consults this flag will scroll (D1/D2).
    public var pendingFocusScroll = false

    /// Whether the global ⌘F Find overlay is showing. Distinct from a surface's own
    /// local filter (`query`/`themeQuery`): Find searches *all* options regardless of
    /// the current surface, so the two search tiers never mean the same thing (U20).
    public var isFinding = false

    /// The global Find query (all-option search), kept separate from the per-surface
    /// `query` so the two-tier search model has no shared, double-meaning field (U20).
    public var findQuery: String = ""

    /// Navigate to a specific option: clear any local filter and the global Find,
    /// select the option's category, and mark it as the focus target so the list
    /// scrolls it into view (D1). The shared navigation primitive behind a global
    /// Find result tap (D2), Customized deep-links (F3), and the Problems deep-link
    /// (G5) — introduced here so those units share one behavior.
    public func focus(optionNamed name: String) {
        query = ""
        endFind()
        // Default: don't scroll unless we arm it for a surface that renders an option row.
        pendingFocusScroll = false

        // `theme` has a dedicated Themes browser and is *filtered out* of the Appearance
        // option list, so routing it to its category would dead-end on a surface that
        // never shows it. Send it to the Themes browser instead (its real home).
        if name == "theme" {
            selectedOptionName = nil
            selection = .themes
            return
        }

        let category = OptionCategorizer.category(for: name)
        selectedOptionName = name
        selection = .category(category)
        // The Keyboard Shortcuts category renders the keybind editor, not an option list,
        // so it has no row to scroll to and would strand the scroll flag. Only arm the
        // scroll for the generic option list.
        if category != OptionCategorizer.keybindingsCategory {
            pendingFocusScroll = true
            focusRequestID &+= 1
        }
    }

    /// Ranked global-search results paired with their provenance (category pill +
    /// intent phrase), for the Find surface (D2).
    public func globalFindHits() -> [(hit: SearchHit, option: MergedOption)] {
        browser?.searchHits(findQuery) ?? []
    }

    /// Open the global Find overlay (⌘F / the toolbar Find button).
    public func beginFind() { isFinding = true }

    /// Dismiss the global Find overlay and clear its query.
    public func endFind() {
        isFinding = false
        findQuery = ""
    }

    // MARK: - Themes (U8)

    /// The currently-applied theme value, if set.
    public var currentTheme: String? {
        browser?.merged.option(named: "theme").flatMap { $0.isSet ? $0.userValues.first : nil }
    }

    /// The themes matching `themeQuery` by name (case- and diacritic-insensitive);
    /// the whole list when the query is empty. The Themes surface renders this instead
    /// of `themes` so its shared-header search field actually filters (C3). Colors still
    /// load lazily per visible row, so filtering never forces an eager color read.
    /// The match itself is the kit's `ThemeParser.nameMatches` (unit-tested there, E1).
    public var filteredThemes: [ThemeRef] {
        let q = themeQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return themes }
        return themes.filter { ThemeParser.nameMatches($0.name, query: q) }
    }

    /// The theme names the current `theme = …` value selects — one for a single
    /// theme, both for a `light:…,dark:…` pair (E2). The Themes browser drives its
    /// "Current" highlight from membership in this set rather than string equality,
    /// so both rows of a pair read as current (`ThemeParser.selectedThemeNames`).
    public var currentSelectedThemeNames: Set<String> {
        guard let currentTheme else { return [] }
        return ThemeParser.selectedThemeNames(currentTheme)
    }

    /// The current theme value parsed into a single/pair selection, for the pinned
    /// "Current theme" section (E2/E4). `nil` when no theme is set.
    public var currentThemeSelection: ThemeSelection? {
        currentTheme.map { ThemeParser.parseThemeSetting($0) }
    }

    /// Whether a theme's color preview failed to load (E3). Reads the private
    /// `failedThemes` set so the Themes browser can render a "Preview unavailable"
    /// placeholder instead of an eternal spinner. Observation tracks the read, so a
    /// row re-renders the moment its load fails.
    public func previewFailed(_ name: String) -> Bool { failedThemes.contains(name) }

    /// Lazily create (once) the shared theme/font provider for the current
    /// environment. Themes, theme colors, and the font list all draw on the same
    /// instance so its caches are shared no matter which surface loads first.
    private func themeProviderIfAvailable() -> ThemeProvider? {
        if let themeProvider { return themeProvider }
        guard let environment else { return nil }
        let provider = ThemeProvider.live(environment)
        themeProvider = provider
        return provider
    }

    /// Load the theme + font lists once, lazily (the Themes tab triggers this).
    public func loadThemesIfNeeded() async {
        guard themes.isEmpty, let provider = themeProviderIfAvailable() else { return }
        themes = (try? await provider.themes()) ?? []
        if fonts.isEmpty { fonts = (try? await provider.fonts()) ?? [] }
    }

    /// Load the available font families once, lazily. The font-family picker in the
    /// Font category triggers this, so the list is populated without first opening
    /// the Themes tab (both share the provider's cache via `themeProviderIfAvailable`).
    public func loadFontsIfNeeded() async {
        guard fonts.isEmpty, let provider = themeProviderIfAvailable() else { return }
        fonts = (try? await provider.fonts()) ?? []
    }

    /// Lazily load (and cache) a theme's colors so swatches render on demand.
    public func ensureColors(for theme: ThemeRef) {
        guard themeColors[theme.name] == nil,
              colorTasks[theme.name] == nil,
              !failedThemes.contains(theme.name), // don't re-fetch a known-bad file every redraw
              let themeProvider else { return }
        let name = theme.name
        colorTasks[name] = Task { [weak self] in
            let colors = try? await themeProvider.colors(for: theme)
            // A cancelled load (environment reloaded) must not write into the new
            // model; cancelInFlightColorLoads has already cleared the dictionary.
            guard let self, !Task.isCancelled else { return }
            self.colorTasks[name] = nil
            if let colors {
                self.themeColors[name] = colors
            } else {
                self.failedThemes.insert(name)
            }
        }
    }

    /// Cancel and forget every in-flight color load (called on re-bootstrap).
    private func cancelInFlightColorLoads() {
        for task in colorTasks.values { task.cancel() }
        colorTasks.removeAll()
    }

    /// Apply a theme by writing `theme = …` via the safe write path (F2). Also used
    /// for a light/dark pair — pass the serialized `light:…,dark:…` string, which is a
    /// single `theme` value (one line), so the pairing rides the same primitive (E4).
    public func applyTheme(_ name: String) async {
        guard let themeOption = browser?.merged.option(named: "theme") else { return }
        await applyEdit(option: themeOption, values: [name])
    }

    /// Whether a theme is starred (E4).
    public func isFavorite(_ name: String) -> Bool { favoriteThemes.contains(name) }

    /// Star / unstar a theme (E4). Persists via the property's `didSet`.
    public func toggleFavorite(_ name: String) {
        if favoriteThemes.contains(name) { favoriteThemes.remove(name) }
        else { favoriteThemes.insert(name) }
    }

    /// Set `name` as the light or dark member of a `light:…,dark:…` pair, keeping the
    /// other member from the current selection (E4). The pure composition (which side
    /// to keep, how to seed from a single/none) is `ThemeParser.updatedPairing`, unit-
    /// tested in the kit; this method just reads the current selection and writes the
    /// serialized result through the same safe path as a single theme.
    public func applyThemeInPair(_ name: String, as role: ThemeRole) async {
        let selection = ThemeParser.updatedPairing(current: currentThemeSelection, setting: name, as: role)
        await applyTheme(ThemeParser.serialize(selection))
    }

    /// The current theme's palette (index→hex) if its colors have loaded, used to seed
    /// unset slots in the palette editor (B8). Empty until loaded, or when no theme is set.
    public func currentThemePalette() -> [Int: String] {
        guard let name = currentTheme, let colors = themeColors[name] else { return [:] }
        return colors.palette
    }

    /// Kick off loading the current theme's colors so the palette editor can seed unset
    /// slots from it: load the theme list (to resolve the `ThemeRef`), then trigger the
    /// lazy per-theme color load. A no-op when no theme is set. Falls back gracefully —
    /// the editor shows blank slots + a hint if the colors never arrive (B8).
    public func loadCurrentThemeColorsIfNeeded() async {
        guard currentTheme != nil else { return }
        await loadThemesIfNeeded()
        guard let name = currentTheme, let ref = themes.first(where: { $0.name == name }) else { return }
        ensureColors(for: ref)
    }

    // MARK: - Keybindings (U5)

    /// The `keybind` repeatable option, joined with the user's bindings. Present
    /// even when unset (the catalog always carries `keybind`), so a first edit
    /// targets the real primary config.
    private var keybindOption: MergedOption? { browser?.merged.option(named: "keybind") }

    /// The action names from `+list-actions`, for the parser and validation.
    public var keybindActionNames: Set<String> { Set(keybindActions.map(\.name)) }

    /// Lazily load (once) Ghostty's default keybinds + action list, mirroring
    /// `loadThemesIfNeeded`. Reset on re-`bootstrap`. Degrades to empty lists when
    /// the binary can't list them (the editor still edits user bindings, R19).
    public func loadKeybindReferenceIfNeeded() async {
        guard keybindReference == nil, let environment else { return }
        let provider = KeybindReferenceProvider.live(environment)
        keybindReference = provider
        let actions = (try? await provider.actions()) ?? []
        // A re-`bootstrap` mid-load clears `keybindReference`; don't repopulate
        // published state from the now-stale provider (mirrors the color-task guard).
        guard keybindReference === provider else { return }
        keybindActions = actions
        let defaults = (try? await provider.defaults()) ?? []
        guard keybindReference === provider else { return }
        keybindDefaults = defaults
    }

    /// Ghostty's defaults merged with the user's bindings, marking overrides (RK1),
    /// then padded with an empty row per still-unbound action so the whole action set
    /// is listed and bindable inline (like a system shortcuts pane).
    ///
    /// "Disabled default" rows are hidden: they're noisy and usually duplicate an
    /// action that's rebound elsewhere ("Restore default" on that action re-enables the
    /// default instead). Dropping them *before* `withUnboundActions` means an action
    /// whose only shortcut was disabled reappears as a bindable "no shortcut" row rather
    /// than vanishing.
    public var mergedKeybinds: [MergedKeybind] {
        let user = KeybindMerge.userBindings(
            values: keybindOption?.userValues ?? [],
            sources: keybindOption?.sources ?? [],
            knownActions: keybindActionNames
        )
        let merged = KeybindMerge.merge(defaults: keybindDefaults, user: user)
            .filter { $0.origin != .userDisablesDefault }
        return KeybindMerge.withUnboundActions(merged, allActions: keybindActions)
    }

    /// Canonical default trigger(s) grouped by *full* action (params included, so
    /// `goto_split:previous` and `goto_split:next` stay distinct), from Ghostty's defaults.
    private var defaultTriggersByAction: [String: Set<String>] {
        Dictionary(grouping: keybindDefaults, by: \.action)
            .mapValues { Set($0.map(\.canonicalTrigger)) }
    }

    /// Actions that have a Ghostty default *and* are currently customized — either the
    /// user disabled one of the action's default triggers, or bound the action to some
    /// trigger. These are the rows that should offer "Restore default".
    public var restorableActions: Set<String> {
        let byAction = defaultTriggersByAction
        guard !byAction.isEmpty else { return [] }
        let user = KeybindMerge.userBindings(
            values: keybindOption?.userValues ?? [],
            sources: keybindOption?.sources ?? [],
            knownActions: keybindActionNames
        )
        var result = Set<String>()
        for binding in user {
            if binding.isUnbind {
                for (action, triggers) in byAction where triggers.contains(binding.canonicalTrigger) {
                    result.insert(action)
                }
            } else if byAction[binding.keybind.action] != nil {
                result.insert(binding.keybind.action)
            }
        }
        return result
    }

    /// Revert an action to Ghostty's default — drops the user's binding(s) for it and
    /// re-enables any of its default triggers the user disabled (via the kit transform).
    public func restoreActionToDefault(action: String) async {
        let triggers = defaultTriggersByAction[action] ?? []
        await writeKeybinds { $0.removingAction(action, defaultTriggers: triggers, knownActions: keybindActionNames) }
    }

    /// The single file the writer would target for `keybind` (R8). New/edited
    /// bindings land here; bindings defined elsewhere are shown read-only (R-F).
    private var keybindTargetPath: String? {
        guard let model = browser?.merged.model else { return nil }
        return ConfigWriter().targetFile(forOption: "keybind", in: model).resolvedPath
    }

    /// True when a merged row's user binding lives outside the writer's target
    /// file, so editing it here would risk duplicating it across files (R-F). Such
    /// rows are rendered read-only by the surface.
    public func isReadOnly(_ row: MergedKeybind) -> Bool {
        guard let source = row.source, let target = keybindTargetPath else { return false }
        return ConfigReader.canonicalPath(source.file) != ConfigReader.canonicalPath(target)
    }

    /// Add a new binding (`originalTrigger == nil`) or update an existing one. When
    /// editing, `originalTrigger` is the row's canonical trigger so a trigger change
    /// *moves* the binding instead of orphaning the old one (R8/R11/RK4). Pre-validates
    /// in the kit (KTD7/RK5) and short-circuits to a failure before touching disk,
    /// then reuses the safe write path (R17).
    public func applyKeybindEdit(originalTrigger: String? = nil, trigger: String, action: String) async {
        let trigger = trigger.trimmingCharacters(in: .whitespaces)
        let action = action.trimmingCharacters(in: .whitespaces)
        let issues = KeybindValidation.validate(trigger: trigger, action: action, knownActions: keybindActionNames)
        if let hardError = issues.first(where: { $0.severity == .error }) {
            applyState = .failed(hardError.message)
            return
        }
        await writeKeybinds { $0.updating(originalTrigger: originalTrigger, trigger: trigger, action: action) }
    }

    /// Rebind a **Ghostty default** to a new trigger from inline recording: write the
    /// new binding *and* disable the old default (`oldTrigger=unbind`) in one write, so
    /// the action moves to the new keys instead of firing on both (the "rebind replaces
    /// the shortcut" expectation). Pre-validates like `applyKeybindEdit`.
    public func rebindDefaultKeybind(oldTrigger: String, newTrigger: String, action: String) async {
        let newTrigger = newTrigger.trimmingCharacters(in: .whitespaces)
        let action = action.trimmingCharacters(in: .whitespaces)
        let issues = KeybindValidation.validate(trigger: newTrigger, action: action, knownActions: keybindActionNames)
        if let hardError = issues.first(where: { $0.severity == .error }) {
            applyState = .failed(hardError.message)
            return
        }
        await writeKeybinds { $0.movingDefault(fromTrigger: oldTrigger, toTrigger: newTrigger, action: action) }
    }

    /// Remove a user binding (any default with that trigger reactivates).
    public func removeKeybind(trigger: String) async {
        await writeKeybinds { $0.removing(trigger: trigger) }
    }

    /// Disable a default by writing `trigger=unbind`.
    public func unbindDefaultKeybind(trigger: String) async {
        await writeKeybinds { $0.unbindingDefault(trigger: trigger) }
    }

    /// Scope the user's keybinds to the writer's target file (R-F), apply a pure
    /// transform to get the next ordered value list, and route it through the
    /// existing repeatable-key write path. A transform that changes nothing is a
    /// no-op (no needless write/backup).
    private func writeKeybinds(_ transform: (TargetScopedBindings) -> [String]) async {
        guard let option = keybindOption, let target = keybindTargetPath else {
            applyState = .failed("Couldn't locate the keybind setting in the catalog.")
            return
        }
        let scoped = TargetScopedBindings(
            userValues: option.userValues,
            sources: option.sources,
            targetResolvedPath: target,
            knownActions: keybindActionNames
        )
        let newValues = transform(scoped)
        guard newValues != scoped.rawValues else { return }
        await applyEdit(option: option, values: newValues)
    }

    /// Count of actionable problems (validation errors + non-info footguns).
    /// Delegates to the kit so the count is derived in one tested place.
    public var problemCount: Int { lintReport?.problemCount ?? 0 }

    // MARK: - Derived view data

    public var categories: [String] {
        browser?.categories ?? []
    }

    /// Options shown in the middle column for the current selection + search.
    public var visibleOptions: [MergedOption] {
        guard let browser else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            return browser.searchResults(q)
        }
        switch selection {
        case .category(let category):
            // `theme` has a dedicated visual home in the Themes browser, so it's
            // dropped from the Colors category list — otherwise the sidebar shows
            // two ways to set the same key ("Themes" + a raw `theme` field). It
            // stays reachable via search and the Customized view, which is the only
            // in-app path to values the picker can't express (a `light:…,dark:…`
            // pair, or a theme name not in `+list-themes`).
            return browser.options(in: category).filter { $0.option.name != "theme" }
        case .customized:
            return browser.customizedOptions
        case .problems:
            return [] // rendered by ProblemsView, not the option list
        case .themes:
            return [] // rendered by ThemeBrowserView
        case .none:
            // Defensive fallback only — the sidebar always keeps a row selected,
            // so this nil branch isn't reachable through normal navigation.
            return browser.merged.options.sorted { $0.option.name < $1.option.name }
        }
    }

    /// The category currently browsed as a plain list, or `nil` when searching or on
    /// a non-category surface (customized/problems/themes) — those never split into
    /// Common/Advanced sections (B1). A search always shows all ranked hits flat.
    private var browsedCategory: String? {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if case .category(let category) = selection { return category }
        return nil
    }

    /// True when the current surface should render Common + collapsible Advanced
    /// sections rather than one flat list (B1).
    public var showsSplitSections: Bool { browsedCategory != nil }

    /// The Common options for the browsed category (curated common tier + promoted
    /// customized options), with `theme` dropped for the same reason `visibleOptions`
    /// drops it — the Themes browser owns it.
    public var commonOptions: [MergedOption] {
        guard let browser, let category = browsedCategory else { return [] }
        return browser.commonOptions(in: category).filter { $0.option.name != "theme" }
    }

    /// The Advanced options for the browsed category, tucked behind the disclosure.
    public var advancedOptions: [MergedOption] {
        guard let browser, let category = browsedCategory else { return [] }
        return browser.advancedOptions(in: category).filter { $0.option.name != "theme" }
    }

    public func selectedOption() -> MergedOption? {
        guard let name = selectedOptionName else { return nil }
        return browser?.merged.option(named: name)
    }

    public func snippet(for option: MergedOption) -> String {
        browser?.snippet(for: option) ?? "\(option.option.name) = \(option.option.defaultValue)"
    }
}

/// The app-side instance lister behind `GhosttyReloader.live` (KTD2/KTD3).
///
/// Lives in the app target — not the kit — because `NSRunningApplication` is AppKit
/// system state the kit deliberately stays free of. It is a plain (`nonisolated`)
/// enum so its static method satisfies the kit's `@Sendable () -> [GhosttyInstance]`
/// seam; the reloader invokes it from `AppModel`'s `@MainActor` context.
enum GhosttyInstanceLister {

    /// Every running Ghostty GUI process (discovered by **bundle id**, never by
    /// process name — a name probe would also match the transient `ghostty +…` CLI
    /// subprocesses this app spawns) mapped to a pid and a **confirmable** version.
    static func runningInstances() -> [GhosttyInstance] {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: GhosttyReloader.ghosttyBundleID)
            .map { GhosttyInstance(pid: $0.processIdentifier, version: confirmableVersion(of: $0)) }
    }

    /// The bundle's `CFBundleShortVersionString` — but **only** when the app can confirm
    /// the running process is actually executing that bundle's code (KTD4 part b). When it
    /// cannot confirm (the on-disk code looks newer than the process, or anything is
    /// unreadable), returns an **empty** string so the kit gate fails closed and never
    /// signals it — `SIGUSR2` to a stale pre-1.2 binary would terminate the user's terminal.
    ///
    /// Confirmation means *the on-disk code was already in place before this process
    /// launched* — `launchDate >= codeDate`. The freshness signal is the **inode change
    /// time (`st_ctime`) of the actual code artifacts** (the loaded executable and
    /// `Info.plist`), taking the latest.
    ///
    /// It is deliberately **not** the `.app` directory's `mtime`, which is a *fail-deadly*
    /// proxy (caught in code review): a directory's `mtime` ignores in-place rewrites of
    /// nested files (so a content-level upgrade leaves it stale), and `mtime` is trivially
    /// preserved by `ditto` / `cp -p` / `rsync -a` / many installers — so an old, still-
    /// running, handler-less build could pass an `mtime` gate and then be **killed** by the
    /// reload signal. `st_ctime` is bumped whenever the inode is created/replaced on the
    /// volume and **cannot be backdated by userspace**, so an in-place or timestamp-
    /// preserving upgrade reliably reads as "newer than the running process" and fails closed.
    private static func confirmableVersion(of app: NSRunningApplication) -> String {
        guard let bundleURL = app.bundleURL,
              let launchDate = app.launchDate,
              let info = bundleInfo(at: bundleURL),
              let codeDate = codeArtifactDate(at: bundleURL, executable: info.executable),
              launchDate >= codeDate else {
            return ""
        }
        return info.version
    }

    /// `(version, executable)` read from the bundle's `Info.plist`, or nil when the version
    /// is missing/unreadable (→ unconfirmable, fail closed). `executable` is the
    /// `CFBundleExecutable` name used to locate the loaded binary for the freshness check.
    private static func bundleInfo(at bundleURL: URL) -> (version: String, executable: String?)? {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return (version, plist["CFBundleExecutable"] as? String)
    }

    /// The latest inode-change time (`st_ctime`) across the artifacts that establish what
    /// the running process is executing: `Info.plist` (carries the version) and the loaded
    /// executable. Returns nil — fail closed — when none can be read. Taking the **max**
    /// biases safe: if *either* artifact landed after the process launched, the instance is
    /// treated as unconfirmable.
    private static func codeArtifactDate(at bundleURL: URL, executable: String?) -> Date? {
        var paths = [bundleURL.appendingPathComponent("Contents/Info.plist").path]
        if let executable {
            paths.append(bundleURL.appendingPathComponent("Contents/MacOS/\(executable)").path)
        }
        return paths.compactMap(inodeChangeDate(ofPath:)).max()
    }

    /// The inode change time (`st_ctime`) of a path. Unlike `mtime`, `st_ctime` cannot be
    /// set by userspace, so it is a trustworthy "when did this land on this machine" signal
    /// for the upgrade-in-place safety gate (KTD4 part b). Uses `stat`, mirroring
    /// `ConfigWriter`'s POSIX helpers.
    private static func inodeChangeDate(ofPath path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let ctime = info.st_ctimespec
        return Date(timeIntervalSince1970: TimeInterval(ctime.tv_sec) + TimeInterval(ctime.tv_nsec) / 1_000_000_000)
    }
}
