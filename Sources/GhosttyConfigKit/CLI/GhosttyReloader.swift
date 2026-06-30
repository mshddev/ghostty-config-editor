import Foundation

/// A running Ghostty GUI instance the app may ask to reload its config (R2).
///
/// Carries the OS process id and a **confirmable** version string — the version
/// the app could positively verify the process is actually running (KTD4). An
/// empty `version` means the running code's version could not be confirmed; the
/// reload gate treats that as unconfirmable and never signals it, because
/// `SIGUSR2` sent to a build without the reload handler would terminate it.
public struct GhosttyInstance: Sendable, Equatable {
    public let pid: pid_t
    /// The confirmable version (e.g. `"1.3.1"`), or empty when unconfirmable.
    public let version: String

    public init(pid: pid_t, version: String) {
        self.pid = pid
        self.version = version
    }
}

/// The result of an auto-reload attempt, with **all** user-facing copy derived
/// here in the kit (KTD8) so it is unit-tested rather than assembled in the view.
///
/// Every `message` is **scope-neutral**: it talks only about the reload, never
/// about whether the edited option needs a new surface or a full restart. The
/// view stacks it as a separate line beneath the option's own `applyNotice`, so
/// the two never compose into a contradictory sentence (KTD8, U2). Mirrors
/// `LintReport.badgeText` — derive the honest copy in the tested kit, not the view.
public enum ReloadOutcome: Equatable, Sendable {
    /// Auto-reload is off; neither the lister nor the sender ran (R7).
    case disabled
    /// No running Ghostty was found to signal (R5).
    case noInstance
    /// Every running instance is a *confirmed* pre-1.2 build with no reload
    /// handler, so none could be safely signaled (R4).
    case versionUnsupported
    /// No running instance's version could be confirmed, so none was signaled —
    /// the fail-safe skip (R4).
    case versionUnknown
    /// At least one instance was signaled (R6). `count` instances were asked to
    /// reload; `skipped` is the number of running instances that were **not**
    /// signaled because their version was too old or unconfirmable (R4) — those
    /// need a manual reload.
    case reloaded(count: Int, skipped: Int)
    /// A confirmed-supported instance was found but the signal was refused, e.g.
    /// `EPERM` (R6) — distinct from a vanished instance.
    case unreachable

    /// The caption to show beneath the "Saved" confirmation, or `nil` when there
    /// is nothing to say (`.disabled`).
    ///
    /// Because `SIGUSR2` is one-way and unacknowledged (KTD5), success copy says
    /// the app *asked* Ghostty to reload — never that the reload itself succeeded.
    public var message: String? {
        switch self {
        case .disabled:
            return nil
        case .noInstance:
            return "Ghostty isn't running — your change will apply the next time you open it."
        case .versionUnsupported:
            return "Ghostty is running a version older than 1.2 — reload it manually (auto-reload needs Ghostty 1.2 or newer)."
        case .versionUnknown:
            return "Couldn't confirm Ghostty's running version — reload it manually (auto-reload only signals a confirmed Ghostty 1.2+)."
        case .unreachable:
            return "Couldn't reach Ghostty to reload it — reload it manually."
        case .reloaded(let count, let skipped):
            let asked = count == 1
                ? "Asked Ghostty to reload its config."
                : "Asked \(count) running Ghostty instances to reload their config."
            guard skipped > 0 else { return asked }
            let manual = skipped == 1
                ? "Another running instance couldn't be auto-reloaded — reload it manually."
                : "\(skipped) other running instances couldn't be auto-reloaded — reload them manually."
            return "\(asked) \(manual)"
        }
    }
}

/// Decides whether and how to ask a running Ghostty to reload its config after an
/// in-app write (R1), and owns the entire safety policy and copy (R2–R6, KTD8).
/// Pure and fully injected so it is unit-tested without ever signaling a live
/// process — the fakes record calls; the real fleet is never touched in tests.
///
/// ## Safety (KTD1, KTD4)
/// `SIGUSR2` is Ghostty's macOS config-reload signal **only** in 1.2.0+. Sent to a
/// process without that handler, the default signal disposition **terminates** it.
/// So this type is fail-safe by construction:
///  - It signals an instance only when its version is *confirmed* `>= 1.2.0` (R4).
///    When it cannot confirm (empty / unparseable version), it skips and tells the
///    user to reload manually — it never signals a process it cannot vouch for.
///  - It refuses structurally dangerous pids (`<= 1`, which would make `kill`
///    broadcast to every process or target a process group / `init`, and the app's
///    own pid) before any signal, and de-duplicates the list (R3).
///
/// The instance lister is intentionally app-supplied (KTD3): `NSRunningApplication`
/// (and the `launchDate >= bundle mtime` confirmation behind the version string) is
/// AppKit/Foundation system state the kit stays free of. So `.live` is a *partial*
/// factory by design — do not "fix" it by dragging AppKit into the kit.
public struct GhosttyReloader: Sendable {

    /// The bundle id every Ghostty macOS GUI process registers under (KTD2),
    /// verified locally at `/Applications/Ghostty.app/Contents/Info.plist`. The app
    /// lister discovers instances by this id, never by process *name* — a name probe
    /// would also match the transient `ghostty +…` CLI subprocesses this app spawns.
    public static let ghosttyBundleID = "com.mitchellh.ghostty"

    /// The lowest Ghostty version whose macOS GUI handles `SIGUSR2` reload (KTD1,
    /// PR #7759, milestone 1.2.0). Below this, the signal terminates the process.
    static let minimumSupportedVersion: (Int, Int, Int) = (1, 2, 0)

    /// Lists running Ghostty GUI instances with a confirmable version (KTD2/KTD3).
    private let runningInstances: @Sendable () -> [GhosttyInstance]
    /// Sends `signal` to `pid`, returning `0` on success or the captured `errno`
    /// (KTD6) so the failure path — `ESRCH` (vanished, benign) vs `EPERM` (blocked)
    /// — is classifiable with injected constants in the unit suite.
    private let send: @Sendable (pid_t, Int32) -> Int32

    public init(
        runningInstances: @escaping @Sendable () -> [GhosttyInstance],
        send: @escaping @Sendable (pid_t, Int32) -> Int32
    ) {
        self.runningInstances = runningInstances
        self.send = send
    }

    /// Wire the real `kill`-based sender, leaving the instance lister to the app
    /// (KTD3). `.live` is deliberately a *partial* factory: the kit owns the signal
    /// and the policy; the app owns the AppKit enumeration.
    public static func live(
        runningInstances: @escaping @Sendable () -> [GhosttyInstance]
    ) -> GhosttyReloader {
        GhosttyReloader(runningInstances: runningInstances, send: { pid, signal in
            // `kill` returns 0 on success, or -1 with `errno` set (KTD6). Surface the
            // errno so the caller can tell ESRCH (vanished, benign) from EPERM (blocked).
            // The errno-after-syscall idiom mirrors `ConfigWriter.stageAndRename`.
            kill(pid, signal) == 0 ? 0 : errno
        })
    }

    /// Ask every confirmed-supported running Ghostty to reload, returning a fully
    /// classified outcome whose `message` is ready to render (KTD8).
    ///
    /// Never throws and never reports an apply failure — reload is best-effort, so a
    /// missing, unreachable, unsupported, unconfirmable, or disabled reload never
    /// turns a successful save into a failure (R5). When `enabled` is false, neither
    /// the lister nor the sender is invoked (R7/AE8).
    public func reload(enabled: Bool) -> ReloadOutcome {
        guard enabled else { return .disabled }

        let safe = safeInstances(runningInstances())
        guard !safe.isEmpty else { return .noInstance }

        // R4: only confirmed `>= 1.2.0` instances are signalable. Everything else is
        // skipped — never signaled — and surfaced for a manual reload.
        let supported = safe.filter { Self.signalReloadSupported(version: $0.version) }
        guard !supported.isEmpty else { return unsignalableOutcome(for: safe) }

        // R4/KTD6: signal only the supported pids; classify each result by errno.
        let skipped = safe.count - supported.count
        var successes = 0
        var blocked = 0
        for instance in supported {
            switch send(instance.pid, SIGUSR2) {
            case 0:
                successes += 1
            case ESRCH:
                break          // instance vanished between list and send — benign (R5)
            default:
                blocked += 1   // EPERM or any other refusal — surfaced as unreachable
            }
        }

        if successes > 0 { return .reloaded(count: successes, skipped: skipped) }
        if blocked > 0 { return .unreachable }
        // Every confirmed-supported instance exited before we could signal it. If
        // unsignalable (old / unconfirmable) instances are still running, give their
        // honest "why not" rather than claiming nothing is running.
        return skipped > 0 ? unsignalableOutcome(for: safe) : .noInstance
    }

    /// R3: keep only structurally safe, de-duplicated pids, preserving first-seen
    /// order. Drops `<= 1` (a `kill` broadcast / process-group / `init` target) and
    /// the app's own pid (a self-signal). This is the hazard gate — a single leaked
    /// unsafe pid could signal the wrong process — so it runs before any classification.
    private func safeInstances(_ instances: [GhosttyInstance]) -> [GhosttyInstance] {
        let selfPID = getpid()
        var seen = Set<pid_t>()
        return instances.filter { instance in
            guard instance.pid > 1, instance.pid != selfPID else { return false }
            return seen.insert(instance.pid).inserted
        }
    }

    /// Classify a set with no signalable instance into the honest "why not" outcome.
    /// Prefers the specific "too old" copy only when every unsignalable instance is a
    /// *confirmed* old build; any unconfirmable instance downgrades to the honest
    /// "couldn't confirm" (fail-safe — we don't claim a version we couldn't read).
    private func unsignalableOutcome(for instances: [GhosttyInstance]) -> ReloadOutcome {
        let confirmedOld = instances.contains { instance in
            guard let parsed = Self.parsedVersion(instance.version) else { return false }
            return parsed < Self.minimumSupportedVersion
        }
        let anyUnconfirmable = instances.contains { Self.parsedVersion($0.version) == nil }
        if confirmedOld && !anyUnconfirmable { return .versionUnsupported }
        if confirmedOld || anyUnconfirmable { return .versionUnknown }
        return .noInstance
    }

    // MARK: - Version gate (pure)

    /// True only when `version` is a *confidently parsed* Ghostty version
    /// `>= 1.2.0` (R4). Fails **closed** (`false`) on any parse ambiguity — an empty
    /// string, non-numeric components, or trailing junk — because a false positive
    /// here terminates the user's terminal (execution note: bias toward `false`).
    public static func signalReloadSupported(version: String) -> Bool {
        guard let parsed = parsedVersion(version) else { return false }
        return parsed >= minimumSupportedVersion
    }

    /// Parse the leading numeric `major.minor.patch` from a version string, ignoring
    /// any `-prerelease` / `+build` suffix, padding missing components with 0.
    /// Returns `nil` — **fail closed** — on any ambiguity so the gate never vouches
    /// for a version it could not positively parse:
    ///  - empty / whitespace-only
    ///  - a non-numeric component (`"garbage"`, `"1.2.x"`, an empty segment)
    ///  - more than three numeric components (an unexpected shape)
    ///
    /// Compared **numerically**, component-wise — so `"1.10.0"` ranks above `"1.2.0"`,
    /// not below it as a lexicographic compare would have.
    static func parsedVersion(_ raw: String) -> (Int, Int, Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Strip at the first SemVer suffix marker (`-` pre-release or `+` build).
        let core = trimmed.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var components = [0, 0, 0]
        for (index, part) in parts.enumerated() {
            guard let value = Int(part), value >= 0 else { return nil }
            components[index] = value
        }
        return (components[0], components[1], components[2])
    }
}
