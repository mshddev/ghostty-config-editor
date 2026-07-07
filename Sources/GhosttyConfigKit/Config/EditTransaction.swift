import Foundation

/// A pure, value-type reducer for a single text-bearing edit (KTD2, U3: R3/R4/R5).
///
/// The color, long-value, and (U4) structured popovers wrap the existing safe-write path
/// with this state machine instead of scattered `@State` + commit-on-close callbacks, so
/// "Apply commits, Cancel discards, incidental dismissal never commits, a stale write is
/// reviewable, a failure retains the draft" is one tested contract rather than per-editor
/// ad-hoc code. It holds NO SwiftUI/AppKit — the view drives it and maps write outcomes
/// back onto it, and the writer/backup/serial-write semantics are untouched underneath.
///
/// Lifecycle (matches the plan's stateDiagram):
///   Clean → Dirty (user changes draft) → Invalid ↔ Dirty (local validation)
///   Dirty → Applying (Apply/Done) → Committed | Stale | Failed
///   Stale → Dirty (Reload & Review — NEVER auto-retry) ; Failed → Dirty (edit) ; Cancel → Clean
///
/// The attempted draft is retained through Stale and Failed so recovery never requires
/// retyping (R5/R3). Reloading a stale edit refreshes the saved value and surfaces BOTH
/// the on-disk value and the draft; a SECOND explicit Apply commits.
public struct EditTransaction: Equatable, Sendable {

    /// The single active phase. The `is…` flags below derive from it so state can never
    /// contradict itself.
    public enum Phase: Equatable, Sendable {
        case clean       // draft == saved, nothing to write
        case dirty       // a locally-valid outstanding change ready to Apply
        case invalid     // local validation failed — cannot Apply until corrected
        case applying    // a write is in flight
        case committed   // the write landed (model refresh returns it to Clean)
        case stale       // refused as changed-on-disk; awaiting an explicit Reload & Review
        case failed      // Ghostty rejected the value; draft retained for correction
        case unavailable // after reload the target option is gone — Apply disabled
    }

    public private(set) var phase: Phase
    /// The value currently saved on disk this edit started from (or was refreshed to after
    /// a stale reload) — the "saved swatch" the editor shows unchanged on Cancel/dismiss.
    public private(set) var savedValue: String
    /// The working draft the user is editing.
    public private(set) var draft: String
    /// After Reload & Review, the externally-changed on-disk value, kept beside the draft
    /// for the side-by-side comparison (F2/AE3). Nil outside that reviewable state.
    public private(set) var refreshedDiskValue: String?
    /// The plain-language reason for the current invalid/failed/stale/unavailable phase
    /// (R3). The caller supplies the normalized text; the reducer only carries it.
    public private(set) var message: String?

    public init(savedValue: String) {
        self.phase = .clean
        self.savedValue = savedValue
        self.draft = savedValue
        self.refreshedDiskValue = nil
        self.message = nil
    }

    // MARK: - Derived flags

    public var isDirty: Bool { phase == .dirty }
    public var isLocallyInvalid: Bool { phase == .invalid }
    public var isApplying: Bool { phase == .applying }
    public var isStale: Bool { phase == .stale }
    public var isFailed: Bool { phase == .failed }
    public var isCommitted: Bool { phase == .committed }
    /// False once a reload discovered the option no longer exists (Apply is disabled).
    public var isTargetAvailable: Bool { phase != .unavailable }

    /// Whether an Apply may start now: only a locally-valid outstanding change (`.dirty`).
    /// Invalid, applying, stale, committed, unavailable, and clean all refuse — which is
    /// how "Apply commits once" and "stale never auto-retries" fall out for free.
    public var canApply: Bool { phase == .dirty }

    // MARK: - Events

    /// The user changed the draft. `locallyValid` is the caller's syntactic check (a color
    /// hex, a known token …); pass `true` when no local check applies. `invalidMessage` is
    /// the reason shown while invalid. Editing back to the exact saved value returns to
    /// Clean (nothing to write) and clears any pending conflict review.
    public mutating func edit(_ newDraft: String, locallyValid: Bool = true, invalidMessage: String? = nil) {
        draft = newDraft
        if !locallyValid {
            phase = .invalid
            message = invalidMessage
        } else if newDraft == savedValue {
            // Reverted to the saved (or just-accepted external) value — nothing outstanding.
            phase = .clean
            message = nil
            refreshedDiskValue = nil
        } else {
            phase = .dirty
            message = nil
        }
    }

    /// Begin an Apply/Done. Returns `true` only when a write actually starts, so repeated
    /// draft callbacks or a double-Apply cannot kick off a second write (R4).
    @discardableResult
    public mutating func beginApply() -> Bool {
        guard canApply else { return false }
        phase = .applying
        message = nil
        return true
    }

    /// The write committed. The saved value becomes the applied draft; the model's refresh
    /// then calls `finishCommit` to return to Clean (Committed → Clean).
    public mutating func markCommitted() {
        savedValue = draft
        refreshedDiskValue = nil
        phase = .committed
        message = nil
    }

    /// The model refreshed its saved value after a commit → back to Clean. `newValue`
    /// re-seeds `savedValue`/`draft` when the refreshed value differs from what we wrote.
    public mutating func finishCommit(savedValue newValue: String? = nil) {
        if let newValue { savedValue = newValue }
        draft = savedValue
        refreshedDiskValue = nil
        phase = .clean
        message = nil
    }

    /// The write was refused because the file changed on disk. The attempted draft is
    /// retained (R5); recovery is an explicit `reloadAndReview`, never an auto-retry.
    public mutating func markStale(message: String? = nil) {
        phase = .stale
        self.message = message
    }

    /// Reload & Review after a stale conflict: refresh the saved value to what is now on
    /// disk and expose it beside the retained draft for comparison (F2/AE3). Returns to a
    /// reviewable Dirty state so a SECOND explicit Apply is required — it never auto-applies.
    /// If the draft already equals the refreshed value, the conflict is resolved → Clean.
    public mutating func reloadAndReview(refreshedDiskValue newValue: String) {
        savedValue = newValue
        message = nil
        if draft == newValue {
            phase = .clean
            refreshedDiskValue = nil
        } else {
            phase = .dirty
            refreshedDiskValue = newValue
        }
    }

    /// Reload & Review found the target option is no longer present. Retain the draft but
    /// stop with an actionable message and disable Apply rather than guessing a target.
    public mutating func markTargetUnavailable(message: String? = nil) {
        phase = .unavailable
        refreshedDiskValue = nil
        self.message = message
    }

    /// Ghostty rejected the value. The attempted draft is retained so the user can correct
    /// it (Failed → Dirty on the next edit); the message is the normalized reason (R3).
    public mutating func markFailed(message: String? = nil) {
        phase = .failed
        self.message = message
    }

    /// Cancel / incidental dismissal (Escape, click-outside): discard the draft and return
    /// to Clean (R4). Never writes.
    public mutating func cancel() {
        draft = savedValue
        refreshedDiskValue = nil
        phase = .clean
        message = nil
    }
}
