import Foundation

/// Pure value models for the two high-friction mini-languages U4 replaces with semantic
/// controls (R7): the `mouse-scroll-multiplier` composite and the `bell-features` flag set.
///
/// Both keep a raw fallback so unknown/future fragments round-trip verbatim (R8): the scroll
/// composite carries any fragment it doesn't model in `unknown`, and the flag set keeps its
/// whole token list, so toggling one labeled feature never rewrites — or drops — the rest.
/// No SwiftUI/AppKit here so the parse/serialize contract is unit-tested (see
/// `StructuredOptionValueTests`), like `GhosttyPalette` and `FontFeatures`.

// MARK: - Scroll multiplier composite

/// `mouse-scroll-multiplier` is either a bare number applied to all devices, or a
/// comma-separated set of `precision:` / `discrete:` fragments (`precision:0.5,discrete:3`).
/// The two labeled keys map to editor fields; every other fragment (a bare value, or a
/// `key:value` we don't recognize) is preserved verbatim so an edit is lossless (R8).
public struct ScrollMultiplierValue: Equatable, Sendable {
    /// The `precision:` device multiplier, or nil when the fragment is absent.
    public var precision: String?
    /// The `discrete:` device multiplier, or nil when the fragment is absent.
    public var discrete: String?
    /// Fragments we don't model (a bare all-devices value, or an unknown `key:value`),
    /// kept in their original relative order and reserialized untouched (R8).
    public var unknown: [String]

    public init(precision: String? = nil, discrete: String? = nil, unknown: [String] = []) {
        self.precision = precision
        self.discrete = discrete
        self.unknown = unknown
    }

    public static func parse(_ raw: String) -> ScrollMultiplierValue {
        var result = ScrollMultiplierValue()
        for fragment in raw.split(separator: ",", omittingEmptySubsequences: true) {
            let piece = fragment.trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            if let value = prefixedValue(piece, key: "precision") {
                result.precision = value          // last-wins, matching Ghostty's parse
            } else if let value = prefixedValue(piece, key: "discrete") {
                result.discrete = value
            } else {
                result.unknown.append(piece)      // bare value / unknown key:value → verbatim (R8)
            }
        }
        return result
    }

    /// Reserialize in a stable canonical order: `precision` first, then `discrete`, then any
    /// preserved unknown fragments in their original order. A nil-or-empty labeled field is
    /// omitted (clearing a field drops its fragment).
    public func serialized() -> String {
        var parts: [String] = []
        if let precision, !precision.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("precision:\(precision)")
        }
        if let discrete, !discrete.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("discrete:\(discrete)")
        }
        parts.append(contentsOf: unknown)
        return parts.joined(separator: ",")
    }

    /// The value after a `key:` prefix (case-insensitive), or nil when the fragment isn't
    /// that key. Only the first colon splits key from value, so a value may itself contain one.
    private static func prefixedValue(_ fragment: String, key: String) -> String? {
        guard let colon = fragment.firstIndex(of: ":") else { return nil }
        let head = fragment[fragment.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        guard head.caseInsensitiveCompare(key) == .orderedSame else { return nil }
        return String(fragment[fragment.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Bell features flag set

/// `bell-features` is a comma-separated list of feature tokens; a `no-` prefix disables a
/// feature and an omitted feature keeps its documented default. The value string is kept as
/// an ordered token list so unknown/future tokens survive verbatim (R8) and toggling one
/// labeled feature preserves every omitted feature and every unknown token (a single edit
/// replaces or appends exactly one token — it never rewrites the whole set).
public struct BellFeaturesValue: Equatable, Sendable {
    /// The features this editor renders as labeled toggles, with each one's documented
    /// default. Verified against Ghostty 1.3.x `bell-features` docs (`attention`/`title`
    /// enabled by default; `system`/`audio`/`border` off) — re-audit on upgrade like the
    /// other curated Ghostty facts.
    public static let knownFeatures: [(name: String, defaultOn: Bool)] = [
        ("system", false),
        ("audio", false),
        ("attention", true),
        ("title", true),
        ("border", false),
    ]

    /// The raw tokens in file order, preserved verbatim for round-tripping (R8).
    public private(set) var tokens: [String]

    public init(tokens: [String] = []) {
        self.tokens = tokens
    }

    public static func parse(_ raw: String) -> BellFeaturesValue {
        let tokens = raw.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return BellFeaturesValue(tokens: tokens)
    }

    /// Whether a feature is currently enabled: the last token naming it wins (`no-` disables);
    /// with no token, a known feature falls back to its documented default (unknown → false).
    public func isEnabled(_ feature: String) -> Bool {
        for token in tokens.reversed() where matches(token, feature) {
            return !hasNoPrefix(token)
        }
        return Self.knownFeatures.first { $0.name == feature.lowercased() }?.defaultOn ?? false
    }

    /// Enable/disable one labeled feature, replacing an existing token for it in place or
    /// appending one. Omitted features and unknown tokens are left untouched.
    public mutating func set(_ feature: String, enabled: Bool) {
        let replacement = enabled ? feature : "no-\(feature)"
        if let index = tokens.lastIndex(where: { matches($0, feature) }) {
            tokens[index] = replacement
        } else {
            tokens.append(replacement)
        }
    }

    public func serialized() -> String {
        tokens.joined(separator: ",")
    }

    // MARK: - Internals

    /// True when a token names the given feature, ignoring any `no-` prefix and case.
    private func matches(_ token: String, _ feature: String) -> Bool {
        baseName(token).caseInsensitiveCompare(feature) == .orderedSame
    }

    private func hasNoPrefix(_ token: String) -> Bool {
        token.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("no-")
    }

    /// The feature name a token refers to, with any leading `no-` stripped.
    private func baseName(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("no-") {
            return String(trimmed.dropFirst(3))
        }
        return trimmed
    }
}
