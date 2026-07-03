import Foundation

/// How a numeric option should be presented and constrained (CONTROLS-1, R4).
///
/// The catalog can't infer a sensible range/step from a single default value
/// (`background-opacity = 1` gives no hint that it's a 0–1 slider), so these are
/// curated per option. Options without a spec fall back to a plain number field.
public struct NumericSpec: Sendable, Codable, Equatable {
    /// The control shape the editor should render.
    public enum Style: String, Sendable, Codable {
        case slider   // bounded continuous value (opacity, contrast)
        case field    // clamped stepper / number field (font size)
        case size     // a byte-size value (scrollback/image storage limits)
    }

    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let unit: String?
    public let style: Style

    public init(min: Double? = nil, max: Double? = nil, step: Double? = nil, unit: String? = nil, style: Style) {
        self.min = min
        self.max = max
        self.step = step
        self.unit = unit
        self.style = style
    }
}

public extension NumericSpec {
    /// Clamp a value into `[min, max]`; an absent bound leaves that side open. The
    /// editor clamps every write so an out-of-range value never reaches disk (B3, R4).
    func clamp(_ value: Double) -> Double {
        var v = value
        if let min, v < min { v = min }
        if let max, v > max { v = max }
        return v
    }

    /// Human-readable byte size for the `.size` style, in decimal (SI) units, e.g.
    /// `320_000_000` → "320 MB". Deliberately locale-free and single-spaced so it's
    /// deterministic to assert on and reads the way a storage limit is spoken (B3).
    static func formatBytes(_ bytes: Double) -> String {
        let units: [(name: String, factor: Double)] = [
            ("GB", 1_000_000_000), ("MB", 1_000_000), ("KB", 1_000),
        ]
        let b = Swift.max(0, bytes)
        for unit in units where b >= unit.factor {
            let scaled = b / unit.factor
            if scaled.rounded() == scaled { return "\(Int(scaled)) \(unit.name)" }
            return String(format: "%.1f %@", scaled, unit.name)
        }
        return "\(Int(b)) bytes"
    }

    /// A sensible step for a *spec-less* numeric field, inferred from the option's
    /// default: a fractional default (e.g. `0.5`) implies fine steps, an integer or
    /// unparseable default implies whole steps. When this returns 1 the editor drops
    /// the stepper entirely (a step-of-1 nudge on an unbounded field is noise); a
    /// fractional step earns a stepper (B3).
    static func inferredStep(forDefault defaultValue: String) -> Double {
        guard let value = Double(defaultValue.trimmingCharacters(in: .whitespaces)) else { return 1 }
        return value.rounded() == value ? 1 : 0.1
    }
}

/// Bundled numeric presentation specs, keyed by option name (A4).
public struct NumericSpecCatalog: Sendable {
    private let specs: [String: NumericSpec]

    public init(specs: [String: NumericSpec]) {
        self.specs = specs
    }

    public func spec(for name: String) -> NumericSpec? { specs[name] }

    /// Option names carrying a spec — used by the orphan-key guard (KTD1).
    public var specOptionNames: Set<String> { Set(specs.keys) }

    private struct File: Codable { let specs: [String: NumericSpec] }

    public static func decode(_ data: Data) throws -> NumericSpecCatalog {
        NumericSpecCatalog(specs: try JSONDecoder().decode(File.self, from: data).specs)
    }

    public static let bundled: NumericSpecCatalog = {
        guard let url = Bundle.module.url(forResource: "numeric-specs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(data) else {
            return NumericSpecCatalog(specs: [:])
        }
        return catalog
    }()
}

/// Friendly labels for cryptic enum *values* (A4, CONTENT-8). Keyed option → value
/// → label so the same raw value can read differently per option; unlabeled values
/// fall back to the raw string.
public struct EnumValueLabels: Sendable {
    private let labels: [String: [String: String]]

    public init(labels: [String: [String: String]]) {
        self.labels = labels
    }

    /// The friendly label for a value, or the raw value when none is curated.
    public func label(option: String, value: String) -> String {
        labels[option]?[value] ?? value
    }

    /// Option names carrying value labels — used by the orphan-key guard (KTD1).
    public var labeledOptionNames: Set<String> { Set(labels.keys) }

    private struct File: Codable { let labels: [String: [String: String]] }

    public static func decode(_ data: Data) throws -> EnumValueLabels {
        EnumValueLabels(labels: try JSONDecoder().decode(File.self, from: data).labels)
    }

    public static let bundled: EnumValueLabels = {
        guard let url = Bundle.module.url(forResource: "enum-value-labels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? decode(data) else {
            return EnumValueLabels(labels: [:])
        }
        return catalog
    }()
}
