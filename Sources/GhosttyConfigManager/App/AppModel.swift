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

    // MARK: - Themes (U8)

    /// The currently-applied theme value, if set.
    public var currentTheme: String? {
        browser?.merged.option(named: "theme").flatMap { $0.isSet ? $0.userValues.first : nil }
    }

    /// Load the theme + font lists once, lazily (the Themes tab triggers this).
    public func loadThemesIfNeeded() async {
        guard themes.isEmpty, let environment else { return }
        let provider = ThemeProvider.live(environment)
        themeProvider = provider
        themes = (try? await provider.themes()) ?? []
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

    /// Apply a theme by writing `theme = …` via the safe write path (F2).
    public func applyTheme(_ name: String) async {
        guard let themeOption = browser?.merged.option(named: "theme") else { return }
        await applyEdit(option: themeOption, values: [name])
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
            return browser.options(in: category)
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
