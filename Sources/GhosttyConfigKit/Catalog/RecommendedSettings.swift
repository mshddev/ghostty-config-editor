import Foundation

/// The curated "Recommended" starting set: a short,
/// separately-authorable list of the high-value options a newcomer usually wants to
/// set first, grouped into a few named sections. Rendered by the Recommended surface
/// (reusing the ordinary option rows), so a newcomer meets ~a dozen meaningful
/// choices instead of the 300-option wall.
///
/// A bundled JSON list rather than a flag on the tiers file: the curation is its own
/// concern (which options to *recommend*), distinct from which tier an option sits in,
/// and a standalone list is easier to re-author. Loaded like `LabelCatalog.bundled`,
/// and — because it names raw option keys that a Ghostty upgrade could rename — guarded
/// by the same orphan-key test the other curated resources carry.
public struct RecommendedSettings: Sendable {

    /// One titled group of recommended options, in author order.
    public struct Section: Sendable, Codable, Equatable {
        public let title: String
        /// Raw option keys (`theme`, `font-size`, …), rendered in this order.
        public let options: [String]

        public init(title: String, options: [String]) {
            self.title = title
            self.options = options
        }
    }

    public let sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    /// Every recommended option key across all sections, in order (a key can't
    /// meaningfully appear twice, but order is preserved rather than deduped so the
    /// orphan-key guard reports exactly what's authored).
    public var optionNames: [String] {
        sections.flatMap(\.options)
    }

    /// Recommended option keys as a set — used by the orphan-key guard so a key
    /// that no longer resolves against the catalog fails a test rather than silently
    /// rendering nothing.
    public var recommendedOptionNames: Set<String> {
        Set(optionNames)
    }

    // MARK: - Bundled resource

    private struct File: Codable { let sections: [Section] }

    public static func decode(_ data: Data) throws -> RecommendedSettings {
        RecommendedSettings(sections: try JSONDecoder().decode(File.self, from: data).sections)
    }

    /// The bundled recommended list (empty if the resource is somehow missing, so the
    /// surface renders an empty state rather than crashing).
    public static let bundled: RecommendedSettings = {
        guard let url = Bundle.module.url(forResource: "recommended-settings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let settings = try? decode(data) else {
            return RecommendedSettings(sections: [])
        }
        return settings
    }()
}
