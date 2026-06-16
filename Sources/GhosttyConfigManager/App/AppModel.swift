import Foundation
import Observation
import GhosttyConfigKit

/// What the sidebar can select.
public enum SidebarSelection: Hashable {
    case all
    case customized
    case unused
    case problems
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

    public private(set) var environmentState: EnvironmentState = .loading
    public private(set) var contentState: ContentState = .idle
    public private(set) var browser: CatalogBrowser?
    /// Validation + footgun report for the loaded config (R15, R16).
    public private(set) var lintReport: LintReport?
    /// True when no config file exists yet — discovery still works against an
    /// all-unset view (R6, first-launch state).
    public private(set) var configMissing = false

    public var binaryOverride: String?
    public var selection: SidebarSelection? = .all
    public var query: String = ""
    public var selectedOptionName: String?

    public init() {}

    /// Locate Ghostty, then load the catalog and merge the user's config.
    public func bootstrap() async {
        environmentState = .loading
        contentState = .idle
        do {
            let environment = try await GhosttyEnvironment.discover(userOverride: binaryOverride)
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
            let reader = ConfigReader()
            let merged: MergedConfig
            do {
                merged = try reader.read(catalog: catalog)
                configMissing = false
            } catch ConfigReadError.notFound {
                // No config yet: present an all-unset view so discovery works.
                let empty = ConfigModel(primary: ConfigFile.parse(text: "", path: ""))
                merged = reader.merge(model: empty, catalog: catalog)
                configMissing = true
            }
            browser = CatalogBrowser(merged: merged, catalog: catalog)
            contentState = .loaded
            lintReport = await ConfigLinter().analyze(
                model: merged.model,
                cli: configMissing ? nil : environment.cli
            )
        } catch {
            contentState = .failed(error.localizedDescription)
        }
    }

    /// Count of actionable problems (validation errors + non-info footguns).
    public var problemCount: Int {
        guard let report = lintReport else { return 0 }
        let validationErrors = (report.validation?.isValid == false)
            ? (report.validation?.messages.count ?? 0) : 0
        let footguns = report.findings.filter { $0.severity != .info }.count
        return validationErrors + footguns
    }

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
        case .unused:
            return browser.unusedOptions
        case .problems:
            return [] // rendered by ProblemsView, not the option list
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
