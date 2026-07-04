import Foundation
import Observation
import AppKit
import GhosttyConfigKit

/// What the sidebar can select.
///
/// `.themes` is the launch default; `.recommended` is the curated "start here"
/// surface (F1), pinned above Themes in Get started but *not* the launch default
/// (the app keeps opening on Themes to preserve its identity). `.customized` and
/// `.problems` are tagged Status rows; the rest map to option categories. A `nil`
/// selection is a defensive fallback that shows the unfiltered option list.
public enum SidebarSelection: Hashable {
    case recommended
    case customized
    case problems
    case themes
    case category(String)
    /// The in-window app-settings pane (G1): Ghostty binary path, config-file location,
    /// and behavior. Replaces the removed ⌘, `Settings` *window* — ⌘, now selects this.
    case settings
}

extension SidebarSelection {
    /// A stable string encoding for `@SceneStorage` last-surface restoration (G2). The
    /// associated-value `.category` case makes the enum non-`RawRepresentable`, so the
    /// codec is hand-rolled: a `category:` prefix carries the category name.
    var storageString: String {
        switch self {
        case .recommended: return "recommended"
        case .customized: return "customized"
        case .problems: return "problems"
        case .themes: return "themes"
        case .settings: return "settings"
        case .category(let name): return "category:\(name)"
        }
    }

    init?(storageString raw: String) {
        switch raw {
        case "recommended": self = .recommended
        case "customized": self = .customized
        case "problems": self = .problems
        case "themes": self = .themes
        case "settings": self = .settings
        default:
            let prefix = "category:"
            guard raw.hasPrefix(prefix) else { return nil }
            self = .category(String(raw.dropFirst(prefix.count)))
        }
    }
}

/// The Themes browser's appearance/favorites filter (U15 / TH-3). In-memory (a session
/// choice, like `selection`/`query`), not a persisted preference.
public enum ThemeFilter: String, CaseIterable, Sendable {
    case all, dark, light, favorites

    /// The segmented-control label.
    public var title: String {
        switch self {
        case .all: return "All"
        case .dark: return "Dark"
        case .light: return "Light"
        case .favorites: return "Favorites"
        }
    }

    /// Whether choosing this filter needs every theme classified light/dark first.
    var needsClassification: Bool { self == .dark || self == .light }
}

/// List vs grid browsing of themes (U15 / TH-5). Persisted like `autoReloadEnabled` —
/// a durable view preference. List is the default (LOCKED 2026-07-04).
public enum ThemeViewMode: String, Sendable {
    case list, grid
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
        /// Saved successfully. `headline` is the lead word — "Saved" for an apply,
        /// "Reverted" for an undo — so an undo stops stacking "Saved" over "Reverted"
        /// (CM-6). `notice` carries a new-surface/restart hint (AE5); `gitTracked` is
        /// true when the file lives in a git working tree (U7); `reload` is the
        /// auto-reload outcome whose kit-derived caption the views stack beneath the
        /// notice (R1, R6 — see `GhosttyReloader`).
        case succeeded(headline: String, notice: String?, gitTracked: Bool, reload: ReloadOutcome)
        /// A write/validation failure. `offersReload` is true only for the stale-on-disk
        /// case, where re-reading disk is the actual fix — so the surface can show an inline
        /// "Reload" (the message says "reload" and now something does, G3/GAP-2). All other
        /// failures pass `false`.
        case failed(String, offersReload: Bool)
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

    /// The user's manual Ghostty binary-path override (G1, FEATURES-2). **Persisted**
    /// across launches via the kit's `BinaryOverrideStore` — read in `init`, written by
    /// `setBinaryOverride(_:)` — so a fix on the "not found" screen survives relaunch.
    /// Read by `bootstrap()` as `GhosttyEnvironment.discover(userOverride:)`.
    public private(set) var binaryOverride: String?
    public var selection: SidebarSelection? = .themes
    public var query: String = ""
    /// The Themes surface's own search text (name filter), bound to the shared
    /// `SurfaceHeader` field. Distinct from `query` so each surface filters itself
    /// and never means two things at once (C3). E1 layers light/dark grouping on top.
    public var themeQuery: String = ""
    /// The Themes browser's appearance/favorites filter (U15). In-memory like `themeQuery`.
    public var themeFilter: ThemeFilter = .all
    public var selectedOptionName: String?

    /// `UserDefaults` key for the themes list/grid toggle (U15).
    static let themeViewModeDefaultsKey = "themeViewMode"

    /// List vs grid browsing of themes (U15 / TH-5). Persisted across launches like
    /// `autoReloadEnabled`; defaults to `.list` (LOCKED 2026-07-04). `didSet` mirrors it
    /// to `UserDefaults` (assigning in `init` doesn't fire `didSet`).
    public var themeViewMode: ThemeViewMode = .list {
        didSet { UserDefaults.standard.set(themeViewMode.rawValue, forKey: Self.themeViewModeDefaultsKey) }
    }

    /// `UserDefaults` key for the auto-reload toggle (KTD7).
    static let autoReloadDefaultsKey = "autoReloadEnabled"

    /// Whether a successful in-app write auto-reloads the running Ghostty (R7, KTD7).
    /// **On by default**; the toggle persists across launches (alongside `binaryOverride`
    /// and `favoriteThemes`; `selection`/`query` remain in-memory). Stored (not computed) so a mid-session
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

    /// `UserDefaults` key for the first-run welcome (F2).
    static let hasSeenWelcomeDefaultsKey = "hasSeenWelcome"

    /// Whether the user has dismissed the first-run welcome at least once (F2).
    /// Persisted like `autoReloadEnabled`; defaults to `false` (a missing key reads
    /// false), so a fresh install shows the welcome. Set true on first *dismiss*, not
    /// on first edit, so the safety story is seen before anything is changed.
    public private(set) var hasSeenWelcome: Bool {
        didSet { UserDefaults.standard.set(hasSeenWelcome, forKey: Self.hasSeenWelcomeDefaultsKey) }
    }

    /// Whether the welcome pane is currently presented (F2). Transient (not persisted):
    /// computed once per launch from `!hasSeenWelcome || configMissing`, cleared on
    /// dismiss, and re-set when re-opened from the Help menu.
    public var isShowingWelcome = false
    /// Guards the once-per-launch welcome evaluation so a re-`bootstrap` (binary-override
    /// change) never re-pops the pane.
    private var welcomeEvaluated = false

    private var environment: GhosttyEnvironment?
    private var catalog: OptionCatalog?
    private var lastReceipt: WriteReceipt?
    /// The last successful inline edit (option name + values), captured so a revert can
    /// be redone by re-issuing it (U6). Edit-replay — it never touches `lastReceipt`.
    private var lastApplyEdit: (name: String, values: [String])?
    /// The edit a Redo would re-apply: set when an undo reverts `lastApplyEdit`, cleared
    /// by the next successful apply. Drives the time-boxed inline Redo link (U6).
    private var redoableApply: (name: String, values: [String])?

    /// Serializes every disk write — single-option applies, batch import/reset, and
    /// undo — so only one is ever in flight (U1/GAP-8). Coalesces a same-option burst
    /// to its latest value; queues everything else FIFO. The public write methods keep
    /// their signatures; enqueuing is an internal detail. See `SerialWriteQueue`.
    private let writeQueue = SerialWriteQueue()

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
    /// Tri-state theme/font list loads (G3): a failed `+list-themes`/`+list-fonts` becomes
    /// a *distinct* `.failed` phase the surface renders as an error + "Try again", instead
    /// of an empty list that spins a `ProgressView` forever (GAP-3). `themes`/`fonts` are
    /// the loaded values, empty until `.loaded`, so their readers stay unchanged.
    public private(set) var themesLoad: ResourceLoad<[ThemeRef]> = .idle
    public private(set) var fontsLoad: ResourceLoad<[String]> = .idle
    public var themes: [ThemeRef] { themesLoad.value ?? [] }
    public var fonts: [String] { fontsLoad.value ?? [] }
    public private(set) var themeColors: [String: ThemeColors] = [:]
    /// Determinate progress of the one-time Dark/Light batch classification (U15): `nil`
    /// when idle, otherwise the number of themes still to read. Drives "Classifying N…".
    /// Doubles as the "already running" guard so a second filter tap doesn't re-enter.
    public private(set) var classifyProgress: Int?
    /// True once every theme has been read for classification, so re-selecting Dark/Light
    /// is instant (memoized — GAP-5). Reset on re-bootstrap with the other theme caches.
    public private(set) var didClassifyAll = false

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
        // List/grid preference survives relaunch; an unknown/absent value falls back to list.
        themeViewMode = ThemeViewMode(rawValue: defaults.string(forKey: Self.themeViewModeDefaultsKey) ?? "") ?? .list
        // Welcome defaults to unseen on a fresh install (missing key → false).
        hasSeenWelcome = defaults.bool(forKey: Self.hasSeenWelcomeDefaultsKey)
        // A prior manual Ghostty binary path survives relaunch (G1), so a fix on the
        // "not found" screen sticks; nil (unset/blank) falls back to auto-detection.
        binaryOverride = BinaryOverrideStore(defaults: defaults).load()
    }

    // MARK: - Binary override (G1)

    /// Set (or clear, with nil) the manual Ghostty binary path, persist it, and
    /// re-discover the environment so the change takes effect immediately (G1). Backs the
    /// Settings "Choose…"/"Use auto-detected" buttons and the "Choose Ghostty…" recovery
    /// on the not-found/unsupported screens. Re-evaluates the first-run welcome (a no-op
    /// after it's been seen) so a fresh discovery with no config still surfaces it.
    public func setBinaryOverride(_ path: String?) async {
        let store = BinaryOverrideStore()
        store.save(path)
        binaryOverride = store.load()
        await bootstrap()
        showWelcomeIfNeeded()
    }

    // MARK: - First-run welcome (F2)

    /// Decide once per launch whether to present the welcome: shown when it's never been
    /// dismissed *or* there's no config yet (so deleting the config later re-surfaces it).
    /// Called after the first `bootstrap`, when `configMissing` is known; guarded so a
    /// later re-bootstrap doesn't re-trigger it.
    public func showWelcomeIfNeeded() {
        guard !welcomeEvaluated else { return }
        welcomeEvaluated = true
        isShowingWelcome = !hasSeenWelcome || configMissing
    }

    /// Re-open the welcome from the Help menu (available at any time).
    public func openWelcome() { isShowingWelcome = true }

    /// Dismiss the welcome and remember it's been seen (F2: on first dismiss, not first edit).
    public func dismissWelcome() {
        isShowingWelcome = false
        hasSeenWelcome = true
    }

    public var canUndo: Bool { lastReceipt?.previousText != nil }

    /// Locate Ghostty, then load the catalog and merge the user's config.
    public func bootstrap() async {
        // A re-bootstrap (e.g. binary-override change) abandons stale theme/color
        // loads and clears caches so themes reload against the new environment.
        cancelInFlightColorLoads()
        themeProvider = nil
        themesLoad = .idle
        themeColors = [:]
        fontsLoad = .idle
        failedThemes = []
        // A batch classification in flight targets the old provider; its per-iteration
        // provider-identity guard stops it feeding this reset state, and the memo restarts.
        classifyProgress = nil
        didClassifyAll = false
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
    ///
    /// Enqueues onto `writeQueue` (U1) keyed by the option name, so a rapid burst of
    /// edits to the same option serializes to one in-flight write and coalesces to the
    /// latest value. `await` returns only when this write — or the coalescing successor
    /// that supersedes it — has fully applied, preserving the contract that a caller may
    /// inspect `applyState` afterwards (e.g. to snap a rejected field back).
    public func applyEdit(option: MergedOption, values: [String]) async {
        let name = option.option.name
        await writeQueue.submit(key: name) { [weak self] in
            await self?.performApplyEdit(optionName: name, values: values)
        }
    }

    /// The actual single-option write, run serially by `writeQueue`. Re-resolves the
    /// option and reads `browser.merged.model` **fresh at execution time** (never
    /// captured at enqueue): the model must reflect the previous write's `refreshConfig`
    /// so the stale-on-disk guard stays meaningful, and coalescing may have skipped the
    /// intervening states the enqueue-time value belonged to.
    private func performApplyEdit(optionName: String, values: [String]) async {
        guard let environment, let browser,
              let option = browser.merged.option(named: optionName) else { return }
        applyingOptionName = optionName
        applyState = .applying
        let writer = ConfigWriter()
        do {
            let receipt = try await writer.validateAndApply(
                optionName: optionName,
                values: values,
                isRepeatable: option.option.isRepeatable,
                in: browser.merged.model,
                cli: environment.cli
            )
            lastReceipt = receipt
            // Remember what to redo-through, and invalidate any prior redo — a fresh
            // apply supersedes a revert that could have been redone (U6).
            lastApplyEdit = (optionName, values)
            redoableApply = nil
            let gitTracked = GitContext.isInsideWorkingTree(path: receipt.resolvedPath)
            if let catalog { await refreshConfig(environment: environment, catalog: catalog) }
            // Best-effort: ask the running Ghostty to reload now that the new bytes are
            // committed (R1). Never throws — the only throwing call here is the write
            // above — and never downgrades a successful save to a failure (R5/KTD5).
            let reload = reloader.reload(enabled: autoReloadEnabled)
            applyState = .succeeded(headline: "Saved", notice: option.option.applyNotice, gitTracked: gitTracked, reload: reload)
        } catch ConfigWriteError.validationFailed(let messages) {
            applyState = .failed(messages.first?.message ?? "The change didn't validate.", offersReload: false)
        } catch ConfigWriteError.staleOnDisk {
            applyState = .failed("This file changed on disk since it was read. Reload and try again.", offersReload: true)
        } catch ConfigWriteError.invalidValue {
            applyState = .failed("That value can't contain a line break.", offersReload: false)
        } catch {
            applyState = .failed(error.localizedDescription, offersReload: false)
        }
    }

    /// Revert the last applied write (R10). Enqueued as a non-coalescable entry so it
    /// serializes behind any pending write rather than racing it.
    public func undoLastApply() async {
        await writeQueue.submit(key: nil) { [weak self] in
            await self?.performUndo()
        }
    }

    /// True while a just-reverted edit can be re-applied — drives the inline Redo link (U6).
    public var canRedoApply: Bool { redoableApply != nil }

    /// Re-apply the edit a prior undo reverted (U6). A single-step redo implemented as
    /// edit-replay: it re-issues `applyEdit` through the same serial queue, so it never
    /// fights the last-write receipt model. Guarded — a no-op when nothing is redoable.
    public func redoLastApply() async {
        guard let edit = redoableApply else { return }
        await writeQueue.submit(key: edit.name) { [weak self] in
            await self?.performApplyEdit(optionName: edit.name, values: edit.values)
        }
    }

    /// The actual undo, run serially by `writeQueue`. Reads `lastReceipt` **at execution
    /// time** (not captured at enqueue), so an undo queued behind a still-pending write
    /// reverts *that* write's bytes — snapshotting the receipt at enqueue would restore
    /// pre-write text over a just-committed write.
    private func performUndo() async {
        guard let environment, let catalog, let receipt = lastReceipt else { return }
        applyState = .applying
        do {
            _ = try ConfigWriter().restore(from: receipt)
            lastReceipt = nil
            // The edit we just reverted becomes redoable (U6) — a single-step redo.
            redoableApply = lastApplyEdit
            await refreshConfig(environment: environment, catalog: catalog)
            // Reload after an undo too, so the live terminal reverts (closes the undo
            // gap — undo previously refreshed only the app's own view) (R1/AE5).
            let reload = reloader.reload(enabled: autoReloadEnabled)
            // "Reverted" as the headline, so the UI stops stacking "Saved" over the
            // revert message (CM-6); the reload caption still rides beneath if present.
            applyState = .succeeded(headline: "Reverted", notice: nil, gitTracked: false, reload: reload)
        } catch {
            applyState = .failed(error.localizedDescription, offersReload: false)
        }
    }

    public func resetApplyState() {
        applyState = .idle
        applyingOptionName = nil
        // Invalidate any pending single-step redo: it's time-boxed to the visible
        // feedback, and after a disk reload the reverted bytes may already be gone (U6).
        redoableApply = nil
    }

    // MARK: - Reload from disk (G3)

    /// Re-read the config from disk and rebuild the browser, reusing the already-
    /// discovered environment/catalog (no rediscovery) (G3/GAP-2). Backs the ⌘R command
    /// and the inline "Reload" recovery on a stale-on-disk failure — the error told the
    /// user to reload and now the app actually does. Clears the apply feedback so a
    /// lingering stale-on-disk banner disappears once memory matches disk.
    public func reloadFromDisk() async {
        guard let environment, let catalog else { return }
        await refreshConfig(environment: environment, catalog: catalog)
        resetApplyState()
    }

    /// True when the primary config's bytes on disk differ from what was last read — an
    /// external edit. A cheap SHA compare (`FileIdentity`), used to gate the on-activate
    /// re-sync so it only fires on a real change and never resets in-app state for a file
    /// that didn't move.
    private var primaryChangedOnDisk: Bool {
        guard let loaded = browser?.merged.model.primary.identity,
              let current = FileIdentity.capture(path: loaded.resolvedPath) else { return false }
        return !loaded.contentMatches(current)
    }

    /// Re-sync from disk when the app regains focus — but only when the file actually
    /// changed externally and nothing is mid-apply, so "Reveal in editor" round-trips
    /// (edit outside, come back, see it) without a spurious reload clobbering an in-app
    /// edit (G3; live FSEvents watching remains a deferred enhancement).
    public func syncFromDiskIfChanged() async {
        if case .applying = applyState { return }
        guard !configMissing, primaryChangedOnDisk else { return }
        await reloadFromDisk()
    }

    // MARK: - Settings pane data (G1)

    /// The resolved Ghostty binary path, shown in the Settings "Ghostty" section — nil
    /// until discovery succeeds (the pane shows a not-found note + "Choose…" then).
    public var resolvedBinaryPath: String? {
        if case .ready(let environment) = environmentState { return environment.binaryPath }
        return nil
    }

    /// Where the primary config file lives (or *would* live on first write) — shown in
    /// the Settings "Config file" section and used by Reveal-in-Finder / create (G1).
    public var configFilePath: String? {
        browser?.merged.model.primary.path
    }

    /// Reveal the config file (or its parent directory when it doesn't exist yet) in the
    /// Finder (G1). Uses the resolved path so a symlinked `~/.config` lands on the real file.
    public func revealConfigInFinder() {
        guard let file = browser?.merged.model.primary else { return }
        let resolved = file.resolvedPath
        if FileManager.default.fileExists(atPath: resolved) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resolved)])
        } else {
            // No file yet — open the directory it would be created in.
            let dir = (resolved as NSString).deletingLastPathComponent
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
        }
    }

    /// Create an empty config file at the primary path when none exists yet (G1), so a
    /// newcomer can open it in an editor before making a first change. Creates the parent
    /// directory as needed, then reloads so `configMissing` clears. A no-op if a file is
    /// already there.
    public func createConfigFileIfMissing() async {
        guard configMissing, let resolved = browser?.merged.model.primary.resolvedPath else { return }
        let dir = (resolved as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: resolved) else { return }
        FileManager.default.createFile(atPath: resolved, contents: Data())
        await reloadFromDisk()
    }

    // MARK: - Import / export / copy / reset (G4)

    /// The whole primary config as text — the source for "Copy full config" and Export.
    public var primaryConfigText: String? {
        browser?.merged.model.primary.serialized()
    }

    /// Options customized in the PRIMARY file — the ones a batch reset can actually clear.
    /// The batch owns only the primary (options set in a `config-file` include are left
    /// untouched), so gating/labelling the reset on the *total* customized count would
    /// promise to reset options it can't, report a false success, and re-offer a reset
    /// that never reduces the count (adversarial review #1). This counts only what will
    /// truly change.
    public var resettableCount: Int {
        guard let browser else { return 0 }
        return browser.customizedOptions.filter { isPrimaryResident($0) }.count
    }

    /// True when a customized option is defined in the primary config file, so the
    /// primary-only batch reset will actually unset it (canonical-path compared, matching
    /// how the writer resolves targets).
    private func isPrimaryResident(_ option: MergedOption) -> Bool {
        guard let primary = browser?.merged.model.primary.resolvedPath else { return false }
        let canonicalPrimary = ConfigReader.canonicalPath(primary)
        return option.sources.contains { ConfigReader.canonicalPath($0.file) == canonicalPrimary }
    }

    /// Copy the full config to the pasteboard (a trivial read; G4).
    public func copyConfigToPasteboard() {
        guard let text = primaryConfigText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Replace the primary config with imported `text` — validated, backed up, and
    /// undoable as one step (G4, replace-with-backup). A config that fails validation is
    /// rejected before anything is written.
    public func importConfig(text: String) async {
        await commitWrite(notice: "Imported configuration.") { model, cli in
            try await ConfigWriter().validateAndImport(text: text, into: model, cli: cli)
        }
    }

    /// Reset the primary file's customized options to their defaults in ONE undoable
    /// batch (G4). Options set in a `config-file` include are left untouched — the batch
    /// owns only the primary — and the reset affordance is gated/counted on
    /// `resettableCount` so it only offers, and reports, what it can actually clear.
    public func resetAllCustomized() async {
        await applyReset(in: nil, notice: "Reset settings to their defaults.")
    }

    /// Reset just one category's customized options in one undoable batch (G4).
    public func resetCategory(_ category: String) async {
        await applyReset(in: category, notice: "Reset \(category) to defaults.")
    }

    private func applyReset(in category: String?, notice: String) async {
        guard let browser else { return }
        // The op set is what the user is looking at when they trigger the reset; the
        // model those ops fold into is resolved fresh at execution (below), so the
        // stale-on-disk guard compares against current bytes.
        let ops = resetOperations(in: category, browser: browser)
        guard !ops.isEmpty else { return }
        await commitWrite(notice: notice) { model, cli in
            try await ConfigWriter().validateAndApplyBatch(operations: ops, in: model, cli: cli)
        }
    }

    /// Build the unset ops for a reset — primary-resident customized options (optionally
    /// filtered to one category). Include-resident options are excluded because the batch
    /// only rewrites the primary; unsetting them would be a silent no-op (review #1).
    /// Repeatable keys carry their flag so the batch reconciles them right.
    private func resetOperations(in category: String?, browser: CatalogBrowser) -> [ConfigWriter.BatchOperation] {
        browser.customizedOptions
            .filter { isPrimaryResident($0) }
            .filter { category == nil || OptionCategorizer.category(for: $0.option.name) == category }
            .map { .unset($0.option.name, isRepeatable: $0.option.isRepeatable) }
    }

    /// Run a whole-file/batch write and map its outcome into `applyState` + refresh +
    /// reload, shared by import and reset (the single-option `applyEdit` keeps its own
    /// path because it anchors feedback to a row via `applyingOptionName`). Enqueued as a
    /// non-coalescable entry on `writeQueue` (U1) so a batch write and a queued
    /// `applyEdit` never run concurrently. The `work` closure receives the model and CLI
    /// **fresh at execution** so its stale-on-disk guard compares against current bytes.
    private func commitWrite(
        notice: String,
        _ work: @escaping @MainActor (ConfigModel, GhosttyCLI?) async throws -> WriteReceipt
    ) async {
        await writeQueue.submit(key: nil) { [weak self] in
            await self?.performCommitWrite(notice: notice, work)
        }
    }

    private func performCommitWrite(
        notice: String,
        _ work: @MainActor (ConfigModel, GhosttyCLI?) async throws -> WriteReceipt
    ) async {
        guard let environment, let catalog, let browser else { return }
        applyingOptionName = nil
        applyState = .applying
        do {
            let receipt = try await work(browser.merged.model, environment.cli)
            lastReceipt = receipt
            // A batch write (import / reset-all / reset-category) isn't a single inline
            // edit, so it carries no single-step redo: clear both, so undoing a batch
            // never offers to redo a stale, unrelated inline edit (U6).
            lastApplyEdit = nil
            redoableApply = nil
            let gitTracked = GitContext.isInsideWorkingTree(path: receipt.resolvedPath)
            await refreshConfig(environment: environment, catalog: catalog)
            let reload = reloader.reload(enabled: autoReloadEnabled)
            applyState = .succeeded(headline: "Saved", notice: notice, gitTracked: gitTracked, reload: reload)
        } catch ConfigWriteError.validationFailed(let messages) {
            applyState = .failed(messages.first?.message ?? "The change didn't validate.", offersReload: false)
        } catch ConfigWriteError.staleOnDisk {
            applyState = .failed("This file changed on disk since it was read. Reload and try again.", offersReload: true)
        } catch ConfigWriteError.invalidValue {
            applyState = .failed("That value can't contain a line break.", offersReload: false)
        } catch {
            applyState = .failed(error.localizedDescription, offersReload: false)
        }
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

    /// The themes matching the active appearance/favorites filter (U15) *and* the
    /// `themeQuery` name search (case- and diacritic-insensitive); the whole list when
    /// both are neutral. The Themes surface renders this instead of `themes` so its
    /// shared-header search field and segmented filter both apply (C3/TH-3). Colors still
    /// load lazily per visible row; the Dark/Light filter reads only *already-classified*
    /// appearance, so `classifyThemesIfNeeded()` — not this getter — is what forces the
    /// batch read. The name match is the kit's `ThemeParser.nameMatches` (unit-tested, E1).
    public var filteredThemes: [ThemeRef] {
        var result = themes
        switch themeFilter {
        case .all: break
        case .dark: result = result.filter { themeColors[$0.name]?.appearance == .dark }
        case .light: result = result.filter { themeColors[$0.name]?.appearance == .light }
        case .favorites: result = result.filter { favoriteThemes.contains($0.name) }
        }
        let q = themeQuery.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { result = result.filter { ThemeParser.nameMatches($0.name, query: q) } }
        return result
    }

    /// On the first Dark/Light filter selection, read every still-unclassified theme's
    /// colors off the main actor so `appearance` resolves for all of them (U15 / GAP-5).
    /// Determinate (`classifyProgress` counts down), cancellable (the per-iteration
    /// provider-identity guard drops a run whose provider was swapped by a re-bootstrap),
    /// and memoized (`didClassifyAll`) so a later Dark/Light tap is instant. Sequential —
    /// but the provider caches by path, so themes already read while scrolling return from
    /// cache and only the genuinely-unread ones cost a file read.
    public func classifyThemesIfNeeded() async {
        // `classifyProgress != nil` is the re-entrancy guard: a run is already in flight.
        guard !didClassifyAll, classifyProgress == nil, let provider = themeProviderIfAvailable() else { return }
        let pending = themes.filter { themeColors[$0.name] == nil && !failedThemes.contains($0.name) }
        // Memoize "done" only when there was actually a full list to classify — a call
        // that somehow arrives before the list loads (themes empty) must not permanently
        // wedge classification off (its `!didClassifyAll` guard would then no-op forever).
        guard !pending.isEmpty else {
            if !themes.isEmpty { didClassifyAll = true }
            return
        }
        classifyProgress = pending.count
        for (index, theme) in pending.enumerated() {
            // A re-bootstrap mid-classify swaps the provider; stop feeding a stale run
            // (the reset already cleared `classifyProgress`/`didClassifyAll`).
            guard themeProvider === provider else { return }
            let colors = try? await provider.colors(for: theme)
            guard themeProvider === provider else { return }
            if let colors { themeColors[theme.name] = colors }
            else { failedThemes.insert(theme.name) }
            classifyProgress = pending.count - (index + 1)
        }
        classifyProgress = nil
        didClassifyAll = true
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

    /// Load the theme + font lists once, lazily (the Themes tab triggers this). A load
    /// is attempted only from `.idle`, so a prior `.failed` isn't silently retried on
    /// every re-appear — retry is the explicit `reloadThemes()` (G3).
    public func loadThemesIfNeeded() async {
        guard case .idle = themesLoad, let provider = themeProviderIfAvailable() else { return }
        themesLoad = .loading
        let result = await ResourceLoad.capture { try await provider.themes() }
        // A re-bootstrap mid-load (binary switch) swaps the provider and resets themesLoad
        // to .idle; don't write this now-stale result back over that reset (review #3,
        // mirroring the keybind loader's `keybindReference === provider` guard).
        guard themeProvider === provider else { return }
        themesLoad = result
        await loadFontsIfNeeded()
    }

    /// Load the available font families once, lazily. The font-family picker in the
    /// Font category triggers this, so the list is populated without first opening
    /// the Themes tab (both share the provider's cache via `themeProviderIfAvailable`).
    public func loadFontsIfNeeded() async {
        guard case .idle = fontsLoad, let provider = themeProviderIfAvailable() else { return }
        fontsLoad = .loading
        let result = await ResourceLoad.capture { try await provider.fonts() }
        guard themeProvider === provider else { return }   // stale after a provider swap (review #3)
        fontsLoad = result
    }

    /// Force a fresh theme-list load regardless of the current phase — backs the
    /// "Try again" button on the failed-themes state so a transient `+list-themes`
    /// failure is recoverable without relaunching (G3).
    public func reloadThemes() async {
        guard let provider = themeProviderIfAvailable() else { return }
        themesLoad = .loading
        let result = await ResourceLoad.capture { try await provider.themes() }
        guard themeProvider === provider else { return }   // stale after a provider swap (review #3)
        themesLoad = result
    }

    /// Force a fresh font-list load (the font picker's "Try again").
    public func reloadFonts() async {
        guard let provider = themeProviderIfAvailable() else { return }
        fontsLoad = .loading
        let result = await ResourceLoad.capture { try await provider.fonts() }
        guard themeProvider === provider else { return }   // stale after a provider swap (review #3)
        fontsLoad = result
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
            applyState = .failed(hardError.message, offersReload: false)
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
            applyState = .failed(hardError.message, offersReload: false)
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
            applyState = .failed("Couldn't locate the keybind setting in the catalog.", offersReload: false)
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
        case .recommended:
            return [] // rendered by RecommendedView
        case .settings:
            return [] // rendered by SettingsView (G1)
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

    /// One titled Recommended group, resolved to the catalog's merged options (F1).
    /// `id` is the section title (unique within the bundled list).
    public struct RecommendedGroup: Identifiable {
        public let id: String
        public let options: [MergedOption]
        public var title: String { id }
    }

    /// The curated "Recommended" sections (F1), each resolved to the merged options
    /// present in the catalog. A key the catalog doesn't carry is skipped — the KTD1
    /// orphan-key test keeps the bundled list honest, but the runtime degrades to a
    /// shorter list rather than a blank row if a future catalog ever drops a key.
    /// `theme` is intentionally *kept* here (unlike the option lists that filter it
    /// out): the Recommended surface renders it as a deep-link into the Themes browser.
    public func recommendedSections() -> [RecommendedGroup] {
        guard let browser else { return [] }
        return RecommendedSettings.bundled.sections.map { section in
            RecommendedGroup(id: section.title,
                             options: section.options.compactMap { browser.merged.option(named: $0) })
        }
    }

    /// Whether the catalog carries an option with this name — gates the Problems
    /// deep-link so only a validation `key` that resolves to a real control becomes a
    /// button (G5); unmapped rows keep their "Reveal in editor" fallback.
    public func hasOption(named name: String) -> Bool {
        browser?.merged.option(named: name) != nil
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
