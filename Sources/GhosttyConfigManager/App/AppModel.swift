import Foundation
import Observation
import GhosttyConfigKit

/// What the sidebar can select.
public enum SidebarSelection: Hashable {
    case all
    case customized
    case unused
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
        } catch {
            contentState = .failed(error.localizedDescription)
        }
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
