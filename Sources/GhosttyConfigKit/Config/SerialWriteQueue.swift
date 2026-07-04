import Foundation

/// Serializes config writes so exactly one hits disk at a time (GAP-8 / KTD2).
///
/// The un-serialized `applyEdit` let a rapid burst of edits (a slider drag, a
/// theme spam-click) run concurrently: each read the *same* pre-refresh model, so
/// the second write to land saw the file "changed on disk" and failed with a
/// self-inflicted stale-on-disk error. This queue guarantees **one write in
/// flight**; a newer edit to the *same* option supersedes its still-queued
/// predecessor **in place** — tail-only, so it never reorders past an interposed
/// undo or a different-option write — while everything else queues FIFO. Each
/// entry runs to completion (all `await`s resolved, including the caller's
/// `refreshConfig`) before the next starts, so the stale-on-disk guard keeps
/// meaning "externally edited" rather than "we raced ourselves".
///
/// The queue is deliberately content-free: it serializes opaque `@Sendable async`
/// work closures and knows nothing about `ConfigWriter`, the model, or the app.
/// That keeps it unit-testable without the `@MainActor` app model — its real
/// callers all hop back to the main actor *inside* their closures.
public actor SerialWriteQueue {

    /// A unit of serialized work. Runs to completion before the next entry starts.
    public typealias Work = @Sendable () async -> Void

    private struct Entry {
        /// The coalescing key — an option name for a single-option edit, or `nil`
        /// for a non-coalescable entry (undo, batch import/reset) that must never
        /// merge with a neighbor.
        let key: String?
        var work: Work
        /// Callers awaiting this entry's completion. When a same-key submission
        /// supersedes this entry, its continuation is appended here too, so the
        /// superseded caller resumes when the surviving successor runs (its intent —
        /// "apply this option" — is satisfied by the later value).
        var continuations: [CheckedContinuation<Void, Never>]
    }

    private var pending: [Entry] = []
    private var isDraining = false

    public init() {}

    /// Enqueue `work` and return immediately once it is queued — *not* when it runs.
    /// Coalesces a same-key tail entry in place. Fire-and-forget callers (and tests
    /// that need to stage several pending entries deterministically) use this.
    public func enqueue(key: String? = nil, work: @escaping Work) {
        append(key: key, work: work, continuation: nil)
    }

    /// Enqueue `work` and suspend until it has fully run — resolving when *this*
    /// entry, or the coalescing successor that supersedes it, completes. Callers that
    /// inspect post-write state after `await` (e.g. snapping a rejected field back to
    /// its saved value) rely on this completion contract.
    public func submit(key: String? = nil, work: @escaping Work) async {
        await withCheckedContinuation { continuation in
            append(key: key, work: work, continuation: continuation)
        }
    }

    /// Shared enqueue path. Supersedes the tail entry in place when it carries the
    /// same non-nil key (a same-option burst collapses to its latest value without
    /// reordering past anything already queued behind it); otherwise appends. Starts
    /// the drain loop when idle.
    private func append(key: String?, work: @escaping Work, continuation: CheckedContinuation<Void, Never>?) {
        if let key, let last = pending.last, last.key == key {
            pending[pending.count - 1].work = work
            if let continuation { pending[pending.count - 1].continuations.append(continuation) }
        } else {
            pending.append(Entry(key: key, work: work, continuations: continuation.map { [$0] } ?? []))
        }
        guard !isDraining else { return }
        isDraining = true
        Task { await self.drain() }
    }

    /// Run entries one at a time until the queue empties. Reentrancy is intended:
    /// while `await entry.work()` suspends, new `append`s land in `pending`, and the
    /// loop picks them up on the next turn. Every entry resumes its waiters exactly
    /// once, after its work resolves.
    private func drain() async {
        while !pending.isEmpty {
            let entry = pending.removeFirst()
            await entry.work()
            for continuation in entry.continuations { continuation.resume() }
        }
        isDraining = false
    }
}
