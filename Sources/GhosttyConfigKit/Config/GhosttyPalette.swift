import Foundation

/// Pure helpers for the `palette` repeatable option, whose values are `index=color`
/// fragments (`palette = 0=#1d1f21`). The editor UI stays thin by parsing the user's
/// current values into slots, applying one edit, and serializing back through the
/// existing repeatable write path.
public enum GhosttyPalette {

    /// The number of ANSI palette slots Ghostty exposes (0–15).
    public static let slotCount = 16

    /// Parse a `palette` value list into `index → color`, ignoring malformed or
    /// out-of-range entries. Trims whitespace around both index and color, and keeps
    /// the *last* occurrence of a repeated index (last-wins, matching Ghostty).
    public static func parse(_ values: [String]) -> [Int: String] {
        var out: [Int: String] = [:]
        for raw in values {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let indexText = raw[raw.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let color = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard let index = Int(indexText), (0..<slotCount).contains(index), !color.isEmpty else { continue }
            out[index] = color
        }
        return out
    }

    /// Serialize `index → color` back to a `index=color` list, sorted by index so the
    /// written file is stable and diff-friendly.
    public static func valueList(_ slots: [Int: String]) -> [String] {
        slots.keys.sorted().map { "\($0)=\(slots[$0]!)" }
    }

    /// Apply one slot edit to an existing value list and return the new list. An empty
    /// color clears that slot (falls back to the theme's palette). Preserves every
    /// other slot untouched.
    public static func setting(index: Int, to color: String, in values: [String]) -> [String] {
        var slots = parse(values)
        let trimmed = color.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            slots[index] = nil
        } else {
            slots[index] = trimmed
        }
        return valueList(slots)
    }
}
