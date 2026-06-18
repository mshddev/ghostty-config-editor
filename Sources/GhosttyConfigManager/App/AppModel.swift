import Foundation
import Observation
import GhosttyConfigKit

/// What the sidebar can select.
public enum SidebarSelection: Hashable {
    case all
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
        /// `gitTracked` is true when the file lives in a git working tree (U7).
        case succeeded(notice: String?, gitTracked: Bool)
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

    public var binaryOverride: String?
    public var selection: SidebarSelection? = .all
    public var query: String = ""
    public var selectedOptionName: String?

    private var environment: GhosttyEnvironment?
    private var catalog: OptionCatalog?
    private var lastReceipt: WriteReceipt?

    // Themes (U8)
    private var themeProvider: ThemeProvider?
    /// In-flight per-theme color loads, kept so they can be cancelled when the
    /// environment is reloaded (rather than leaking and writing into stale state).
    private var colorTasks: [String: Task<Void, Never>] = [:]
    private var failedThemes: Set<String> = []
    public private(set) var themes: [ThemeRef] = []
    public private(set) var themeColors: [String: ThemeColors] = [:]
    public private(set) var fonts: [String] = []

    public init() {}

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
            applyState = .succeeded(notice: option.option.applyNotice, gitTracked: gitTracked)
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
            applyState = .succeeded(notice: "Reverted to the previous value.", gitTracked: false)
        } catch {
            applyState = .failed(error.localizedDescription)
        }
    }

    public func resetApplyState() {
        applyState = .idle
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
        case .all, .none:
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
