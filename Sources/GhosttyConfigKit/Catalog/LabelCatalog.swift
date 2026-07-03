import Foundation

/// Plain-language names and one-line summaries for config options (R1, CONTENT-1).
///
/// Ghostty's catalog names options by their raw config key (`background-opacity`,
/// `macos-titlebar-style`). Those are precise but unfriendly to a newcomer, so
/// every option gets a `displayTitle` — a curated name when we have one, otherwise
/// a humanized form of the raw key — and a best-effort `shortSummary`.
///
/// Two guarantees the views rely on:
///   - `displayTitle` is **always non-empty** (curated → humanizer), so no row ever
///     renders a blank name even for the 300+ long-tail options we don't curate.
///   - The raw key is never lost: search still matches it (see `CatalogSearch`), so
///     a power user who knows an option by its config name always finds it (R8).
///
/// `shortSummary` is best-effort and **may be empty** — curated summary, else the
/// first sentence of the option's own docs, else nothing.
public struct LabelCatalog: Sendable {

    /// A curated label for one option. `summary` is optional — many options carry a
    /// good title but lean on their docs for the description.
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

    /// Option names that carry a curated label — used by the orphan-key guard so a
    /// key that no longer resolves against the catalog fails a test (KTD1).
    public var curatedOptionNames: Set<String> {
        Set(curated.keys)
    }

    // MARK: - Read API

    /// The friendly name for an option. Curated title wins; otherwise the humanized
    /// raw key. Never empty (R1).
    public func displayTitle(for name: String) -> String {
        if let title = curated[name]?.title, !title.isEmpty { return title }
        return Self.humanize(name)
    }

    /// A one-line description for an option. Curated summary wins, then the first
    /// sentence of its docs, then empty (R1 is satisfied by the always-present
    /// title, so an empty summary is acceptable).
    public func shortSummary(for name: String, documentation: String) -> String {
        if let summary = curated[name]?.summary, !summary.isEmpty { return summary }
        return Self.firstSentence(documentation)
    }

    // MARK: - Fallbacks

    /// Canonical casing for tokens that shouldn't be Title-Cased naively. Keyed by
    /// the lowercased raw token; re-audit when new acronym-bearing keys appear.
    private static let acronyms: [String: String] = [
        "macos": "macOS", "gtk": "GTK", "osc": "OSC", "x11": "X11",
        "vt": "VT", "kam": "KAM", "css": "CSS", "url": "URL",
        "dpi": "DPI", "rgb": "RGB", "srgb": "sRGB", "id": "ID",
        "ui": "UI", "gpu": "GPU", "cpu": "CPU", "api": "API",
        "sgr": "SGR", "csi": "CSI", "esc": "ESC", "ansi": "ANSI",
    ]

    /// Turn a raw kebab-case key into a sentence-case phrase: first word
    /// capitalized, the rest lowercased, with known acronyms cased canonically.
    /// `humanize("adjust-cell-height")` → "Adjust cell height";
    /// `humanize("macos-titlebar-style")` → "macOS titlebar style".
    public static func humanize(_ name: String) -> String {
        let words = name.split(separator: "-").map(String.init)
        guard !words.isEmpty else { return name }
        var out: [String] = []
        for (index, raw) in words.enumerated() {
            let lower = raw.lowercased()
            if let acronym = acronyms[lower] {
                out.append(acronym)
            } else if index == 0 {
                out.append(lower.prefix(1).uppercased() + lower.dropFirst())
            } else {
                out.append(lower)
            }
        }
        return out.joined(separator: " ")
    }

    /// The first sentence of a doc block, collapsed to one line and capped in
    /// length so it fits a subtitle. Truncation lands on a word boundary with an
    /// ellipsis. Returns "" for empty docs.
    public static func firstSentence(_ documentation: String, maxLength: Int = 120) -> String {
        let flat = documentation
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return "" }

        var sentence = flat
        if let boundary = flat.range(of: ". ") {
            sentence = String(flat[..<boundary.lowerBound]) + "."
        }

        if sentence.count > maxLength {
            let cut = sentence.prefix(maxLength)
            if let lastSpace = cut.lastIndex(of: " ") {
                sentence = cut[..<lastSpace].trimmingCharacters(in: .whitespaces) + "…"
            } else {
                sentence = cut.trimmingCharacters(in: .whitespaces) + "…"
            }
        }
        return sentence
    }

    /// A short example value mined from a doc block — the first backtick-quoted token
    /// that reads like a value (not the option's own name, no newline, bounded length)
    /// — for use as a text-field placeholder on untyped options (B4, CONTROLS-17).
    /// Returns "" when the docs offer nothing usable.
    ///
    /// `--docs` prose quotes concrete values in backticks (`` `xterm-256color` ``), so
    /// this surfaces the shape of a valid value without curating one per option.
    public static func exampleValue(from documentation: String, excluding name: String = "") -> String {
        let parts = documentation.components(separatedBy: "`")
        guard parts.count >= 3 else { return "" }   // need at least one `…` pair
        // Odd indices sit inside a backtick pair.
        for index in stride(from: 1, to: parts.count, by: 2) {
            let token = parts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token != name, token.count <= 40, !token.contains("\n") else { continue }
            return token
        }
        return ""
    }

    // MARK: - Bundled resource

    private struct File: Codable { let labels: [String: Label] }

    public static func decode(_ data: Data) throws -> LabelCatalog {
        LabelCatalog(curated: try JSONDecoder().decode(File.self, from: data).labels)
    }

    /// The bundled curated labels (empty if the resource is somehow missing —
    /// every option then falls back to the humanizer, so nothing renders blank).
    public static let bundled: LabelCatalog = {
        guard let url = Bundle.module.url(forResource: "option-labels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(data) else {
            return LabelCatalog(curated: [:])
        }
        return catalog
    }()
}
