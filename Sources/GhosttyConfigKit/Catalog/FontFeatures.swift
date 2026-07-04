import Foundation

/// The tag arithmetic behind the Ligatures toggle (CV-9). `font-feature` is a loose,
/// repeatable list where each entry is one setting (`ss01`, `-calt`) or a comma-list of
/// them. Ghostty disables the standard programming ligatures with `-calt, -liga, -dlig`
/// (its own documented recommendation), so "ligatures on/off" is really "are those three
/// disable tags present?". Kept in the kit — separate from any view — so the add/remove
/// diff is unit-tested rather than trusted by eye.
public enum FontFeatures {
    /// The three tags Ghostty documents for turning programming ligatures off.
    public static let ligatureDisableTags = ["-calt", "-liga", "-dlig"]

    /// Ligatures read as **on** unless the user has explicitly disabled one of the
    /// standard sets — i.e. none of the disable tags appears anywhere in the list
    /// (an empty/default list is ligatures-on).
    public static func ligaturesEnabled(_ values: [String]) -> Bool {
        let disable = Set(ligatureDisableTags.map(normalize))
        return !tokens(values).contains { disable.contains($0) }
    }

    /// Turn ligatures **off**: strip any partial/duplicate disable tags first, then
    /// append the full set — so the result is deterministic and never double-lists a
    /// tag — while preserving every other user feature (`ss01`, …).
    public static func disablingLigatures(_ values: [String]) -> [String] {
        removingTags(ligatureDisableTags, from: values) + ligatureDisableTags
    }

    /// Turn ligatures **on**: drop only the disable tags, preserving user-added feature
    /// tags like `ss01`.
    public static func enablingLigatures(_ values: [String]) -> [String] {
        removingTags(ligatureDisableTags, from: values)
    }

    // MARK: - Internals

    /// Every individual feature token across the value list (an entry may itself be a
    /// comma-separated list), normalized for comparison.
    private static func tokens(_ values: [String]) -> [String] {
        values.flatMap { $0.split(separator: ",") }.map { normalize(String($0)) }
    }

    /// Remove the given tags from every entry — splitting comma-lists, dropping any
    /// entry that becomes empty — preserving the order and original casing of what
    /// remains.
    private static func removingTags(_ tags: [String], from values: [String]) -> [String] {
        let drop = Set(tags.map(normalize))
        var result: [String] = []
        for entry in values {
            let kept = entry.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !drop.contains(normalize($0)) }
            if !kept.isEmpty { result.append(kept.joined(separator: ", ")) }
        }
        return result
    }

    /// Ghostty's feature tags are case-insensitive; compare trimmed + lower-cased.
    private static func normalize(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
