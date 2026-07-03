import Foundation

/// The tier + within-category rank for one option (IA-1, IA-3).
public struct OptionTier: Sendable, Codable, Equatable {
    public enum Tier: String, Sendable, Codable {
        case common     // shown first, above the Advanced disclosure
        case advanced   // tucked behind the Advanced disclosure
    }
    public let tier: Tier
    /// Ordering key within a category (lower sorts first). Only meaningful for
    /// `common` options; advanced options fall back to name order.
    public let rank: Int

    public init(tier: Tier, rank: Int) {
        self.tier = tier
        self.rank = rank
    }
}

/// Bundled common/advanced tiering, keyed by option name (A3).
///
/// Only the curated **Common** set is listed; every other option defaults to
/// `advanced` with no rank, so the tier data stays small and an option we forget
/// to tier simply lands under Advanced (a safe default) rather than vanishing.
public struct OptionTierCatalog: Sendable {
    private let tiers: [String: OptionTier]

    public init(tiers: [String: OptionTier]) {
        self.tiers = tiers
    }

    public func tier(for name: String) -> OptionTier.Tier { tiers[name]?.tier ?? .advanced }
    public func isCommon(_ name: String) -> Bool { tiers[name]?.tier == .common }
    /// The within-category rank, or a sentinel that sorts after every ranked option.
    public func rank(for name: String) -> Int { tiers[name]?.rank ?? Int.max }

    /// Option names carrying an explicit tier — used by the orphan-key guard (KTD1).
    public var tieredOptionNames: Set<String> { Set(tiers.keys) }

    private struct File: Codable { let tiers: [String: OptionTier] }

    public static func decode(_ data: Data) throws -> OptionTierCatalog {
        OptionTierCatalog(tiers: try JSONDecoder().decode(File.self, from: data).tiers)
    }

    public static let bundled: OptionTierCatalog = {
        guard let url = Bundle.module.url(forResource: "option-tiers", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(data) else {
            return OptionTierCatalog(tiers: [:])
        }
        return catalog
    }()
}

/// The single comparator for ordering options within a category (IA-1).
///
/// Both the category list (`OptionCatalog.options(in:)`) and search
/// (`CatalogBrowser.options(in:)`) sort through this, so browsing and searching
/// agree on order. Sorts by `(isCommon desc, curatedRank asc, name asc)`: the
/// curated common settings float to the top in their curated order, then
/// everything else alphabetically. Total and stable.
public enum OptionOrdering {
    public static func compare(_ lhs: CatalogOption, _ rhs: CatalogOption) -> Bool {
        let tiers = OptionTierCatalog.bundled
        let lCommon = tiers.isCommon(lhs.name)
        let rCommon = tiers.isCommon(rhs.name)
        if lCommon != rCommon { return lCommon }            // common before advanced
        let lRank = tiers.rank(for: lhs.name)
        let rRank = tiers.rank(for: rhs.name)
        if lRank != rRank { return lRank < rRank }           // curated order within common
        return lhs.name < rhs.name                           // then alphabetical
    }
}
