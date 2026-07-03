import Foundation

/// Curated phrase → option(s) map for intent/behavior search (R4, KTD7). Loaded
/// from a bundled JSON resource; deliberately small and hand-maintained rather
/// than heuristic/ML.
public struct IntentMap: Sendable {
    public struct Entry: Sendable, Codable, Equatable {
        public let phrases: [String]
        public let options: [String]
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    private struct File: Codable { let entries: [Entry] }

    public static func decode(_ data: Data) throws -> IntentMap {
        IntentMap(entries: try JSONDecoder().decode(File.self, from: data).entries)
    }

    /// The bundled curated map (empty if the resource is somehow missing).
    public static let bundled: IntentMap = {
        guard let url = Bundle.module.url(forResource: "intent-map", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let map = try? decode(data) else {
            return IntentMap(entries: [])
        }
        return map
    }()

    /// Option names whose entry has a phrase matching the query. A phrase matches
    /// when it contains the query or the query contains it, so "title bar" hits
    /// the "hide title bar" entry and vice versa.
    public func options(matching query: String) -> [String] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var result: [String] = []
        var seen = Set<String>()
        for entry in entries where entry.phrases.contains(where: { phrase in
            let p = phrase.lowercased().trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { return false } // an empty phrase must not match everything
            return p.contains(q) || q.contains(p)
        }) {
            for option in entry.options where seen.insert(option).inserted {
                result.append(option)
            }
        }
        return result
    }
}

/// A single search result with provenance and a ranking score.
public struct SearchHit: Sendable, Equatable {
    public enum MatchKind: String, Sendable, Equatable {
        case intent
        case name
        case documentation
    }
    public let optionName: String
    public let matchKind: MatchKind
    public let score: Int
}

/// Layered option search: curated intent map → option-name match → doc full-text
/// (KTD7, R3, R4).
public struct CatalogSearch: Sendable {
    public let catalog: OptionCatalog
    public let intentMap: IntentMap

    public init(catalog: OptionCatalog, intentMap: IntentMap = .bundled) {
        self.catalog = catalog
        self.intentMap = intentMap
    }

    public func search(_ query: String) -> [SearchHit] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }

        var best: [String: SearchHit] = [:]
        func consider(_ name: String, _ kind: SearchHit.MatchKind, _ score: Int) {
            guard catalog.option(named: name) != nil else { return } // ignore stale map entries
            if let existing = best[name], existing.score >= score { return }
            best[name] = SearchHit(optionName: name, matchKind: kind, score: score)
        }

        // 1. Intent map (highest priority).
        for name in intentMap.options(matching: q) {
            consider(name, .intent, 300)
        }
        // 2. Option-name match (prefix ranks above substring).
        for option in catalog.options where option.name.lowercased().contains(q) {
            consider(option.name, .name, option.name.lowercased().hasPrefix(q) ? 250 : 200)
        }
        // 3. Documentation full-text (fallback).
        for option in catalog.options where option.documentation.lowercased().contains(q) {
            consider(option.name, .documentation, 100)
        }

        return best.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.optionName < $1.optionName
        }
    }
}

/// View-facing helper over a `MergedConfig`: category browsing, search, the
/// discovery (unused) surface, and copy-snippet generation. Pure and Sendable so
/// the SwiftUI layer stays thin and the logic is fully testable (R3, R4, R6).
public struct CatalogBrowser: Sendable {
    public let merged: MergedConfig
    public let search: CatalogSearch

    public init(merged: MergedConfig, catalog: OptionCatalog, intentMap: IntentMap = .bundled) {
        self.merged = merged
        self.search = CatalogSearch(catalog: catalog, intentMap: intentMap)
    }

    public var categories: [String] {
        OptionCategorizer.orderedCategories(present: Set(merged.options.map(\.option.category)))
    }

    public func options(in category: String) -> [MergedOption] {
        merged.options(in: category).sorted { OptionOrdering.compare($0.option, $1.option) }
    }

    /// The category's **Common** options — the curated common tier, plus any
    /// *customized* advanced option auto-promoted so a changed setting is never
    /// hidden behind the Advanced disclosure (IA-2, R2). Preserves the shared
    /// `OptionOrdering` sort, so curated commons lead in their curated order and
    /// promoted options trail alphabetically.
    public func commonOptions(in category: String) -> [MergedOption] {
        options(in: category).filter(Self.isCommon)
    }

    /// The category's **Advanced** options — everything not shown in Common, i.e.
    /// advanced-tier options still at (or unset from) their default. A customized
    /// advanced option moves up to Common and so is absent here.
    public func advancedOptions(in category: String) -> [MergedOption] {
        options(in: category).filter { !Self.isCommon($0) }
    }

    /// Common ⟺ curated-common by name **or** customized (changed from default).
    /// The promotion keys on `.setNonDefault` (not merely `isSet`) so an advanced
    /// option explicitly written to its default stays advanced.
    private static func isCommon(_ option: MergedOption) -> Bool {
        OptionTierCatalog.bundled.isCommon(option.option.name) || option.state == .setNonDefault
    }

    /// Search results as merged options, in ranked order.
    public func searchResults(_ query: String) -> [MergedOption] {
        search.search(query).compactMap { hit in merged.option(named: hit.optionName) }
    }

    /// The "you're not using this" discovery surface (R6).
    public var unusedOptions: [MergedOption] {
        merged.unusedOptions.sorted { $0.option.name < $1.option.name }
    }

    /// Options the user has customized (set to a non-default value).
    public var customizedOptions: [MergedOption] {
        merged.customizedOptions.sorted { $0.option.name < $1.option.name }
    }

    /// A copy-pasteable, syntactically valid config snippet for an option. Uses
    /// the user's value if set, otherwise the default. Repeatable keys emit one
    /// line per value.
    public func snippet(for option: MergedOption) -> String {
        let values = option.isSet ? option.userValues : option.option.defaultValues
        let safeValues = values.isEmpty ? [""] : values
        return safeValues.map { "\(option.option.name) = \($0)" }.joined(separator: "\n")
    }
}
