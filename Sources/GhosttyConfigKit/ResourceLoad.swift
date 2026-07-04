import Foundation

/// The tri-state of a lazily-loaded resource (theme list, font list) so the UI can
/// tell "still loading" from "load failed" — the distinction the app was missing when
/// a failed `+list-themes` left `themes` empty and spun a `ProgressView` forever (G3,
/// GAP-3). `.capture` is the load classifier: it never swallows a thrown error into an
/// empty `.loaded`, which reads to the UI as "no data" and is exactly the eternal-spinner
/// bug this type exists to kill.
public enum ResourceLoad<Value: Sendable & Equatable>: Equatable, Sendable {
    /// Not requested yet.
    case idle
    /// A load is in flight.
    case loading
    /// Loaded successfully (an empty value is a legitimate "loaded, but nothing there").
    case loaded(Value)
    /// The load threw; carries a human-readable reason for the retry surface.
    case failed(String)

    /// Run a throwing load and classify the outcome — `.loaded` on success, `.failed`
    /// with the error's description on throw. Crucially it does **not** map a throw to an
    /// empty success, so callers can render an error + retry instead of a false "empty".
    public static func capture(_ work: @Sendable () async throws -> Value) async -> ResourceLoad {
        do { return .loaded(try await work()) }
        catch { return .failed(error.localizedDescription) }
    }

    /// The loaded value, or nil in any other state.
    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    /// True only in the `.failed` state (for a "show the retry affordance" check).
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The failure reason when failed, else nil.
    public var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}
