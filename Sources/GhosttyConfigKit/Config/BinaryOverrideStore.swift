import Foundation

/// Persists the user's manual Ghostty binary-path override across launches (G1,
/// FEATURES-2). Lives in the kit — not inline in `AppModel` — so the round-trip is
/// genuinely unit-testable (the app target has no harness). A blank/whitespace path
/// clears the override, so "Use auto-detected" is just `save(nil)`.
public struct BinaryOverrideStore {
    public static let defaultsKey = "ghosttyBinaryOverride"

    private let defaults: UserDefaults

    /// Inject a throwaway `UserDefaults(suiteName:)` in tests; production uses `.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The persisted override, or nil when unset or blank.
    public func load() -> String? {
        Self.normalize(defaults.string(forKey: Self.defaultsKey))
    }

    /// Persist `path` (trimmed). A nil/blank path removes the override so discovery
    /// falls back to auto-detection.
    public func save(_ path: String?) {
        if let value = Self.normalize(path) {
            defaults.set(value, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    /// Trim surrounding whitespace; treat blank as "no override".
    public static func normalize(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
