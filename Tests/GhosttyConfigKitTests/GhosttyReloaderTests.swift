import XCTest
import Foundation
@testable import GhosttyConfigKit

/// Tests for the auto-reload decision + safety policy (R2–R6, KTD4).
///
/// Everything here uses **injected fakes** (mirroring `BinaryLocatorTests`, *not*
/// `GhosttyCLITests`' real-process style): the reloader must never signal a live
/// process from the suite. The `Fakes` recorder captures every `send` call so the
/// hazard-adjacent guards — the PID safety filter, the `SIGUSR2` signal number, and
/// the version comparator — are asserted directly.
final class GhosttyReloaderTests: XCTestCase {

    /// Records lister/sender calls and returns scripted errno values per pid, so a
    /// test can assert exactly which pids were signaled (and that none were when the
    /// gate should refuse). `@unchecked Sendable`: the reloader invokes the closures
    /// synchronously on the test thread, so the plain mutable state is safe here.
    private final class Fakes: @unchecked Sendable {
        var instances: [GhosttyInstance] = []
        var errnoByPID: [pid_t: Int32] = [:]
        private(set) var listerCalls = 0
        private(set) var sendCalls: [(pid: pid_t, signal: Int32)] = []

        func reloader() -> GhosttyReloader {
            GhosttyReloader(
                runningInstances: { [self] in listerCalls += 1; return instances },
                send: { [self] pid, signal in
                    sendCalls.append((pid, signal))
                    return errnoByPID[pid] ?? 0
                }
            )
        }

        var signaledPIDs: [pid_t] { sendCalls.map(\.pid) }
    }

    // MARK: - Disabled / no-instance short-circuits (R5, R7)

    func testDisabledNeverEnumeratesOrSignals() {
        let fakes = Fakes()
        fakes.instances = [GhosttyInstance(pid: 4242, version: "1.3.1")]
        let outcome = fakes.reloader().reload(enabled: false)
        XCTAssertEqual(outcome, .disabled)
        XCTAssertEqual(fakes.listerCalls, 0, "disabled must not even enumerate instances (R7)")
        XCTAssertTrue(fakes.sendCalls.isEmpty, "disabled must not signal")
    }

    func testNoRunningInstanceYieldsNoInstance() {
        let fakes = Fakes()
        fakes.instances = []
        let outcome = fakes.reloader().reload(enabled: true)
        XCTAssertEqual(outcome, .noInstance)
        XCTAssertTrue(fakes.sendCalls.isEmpty)
    }

    // MARK: - Happy path + signal-number guard (R2, R6)

    func testSingleSupportedInstanceIsSignaledWithSIGUSR2() {
        let fakes = Fakes()
        fakes.instances = [GhosttyInstance(pid: 4242, version: "1.3.1")]
        let outcome = fakes.reloader().reload(enabled: true)
        XCTAssertEqual(outcome, .reloaded(count: 1, skipped: 0))
        XCTAssertEqual(fakes.sendCalls.count, 1)
        XCTAssertEqual(fakes.sendCalls.first?.pid, 4242)
        // Guards against an accidental SIGUSR1 / SIGTERM / SIGKILL — sending the wrong
        // signal could terminate the user's terminal instead of reloading it.
        XCTAssertEqual(fakes.sendCalls.first?.signal, SIGUSR2)
    }

    func testMultipleSupportedInstancesEachSignaledOnce() {
        let fakes = Fakes()
        fakes.instances = [
            GhosttyInstance(pid: 10, version: "1.2.0"),
            GhosttyInstance(pid: 11, version: "1.3.0"),
            GhosttyInstance(pid: 12, version: "2.0.0"),
        ]
        let outcome = fakes.reloader().reload(enabled: true)
        XCTAssertEqual(outcome, .reloaded(count: 3, skipped: 0))
        XCTAssertEqual(Set(fakes.signaledPIDs), [10, 11, 12])
        XCTAssertTrue(fakes.sendCalls.allSatisfy { $0.signal == SIGUSR2 })
    }

    // MARK: - PID safety filter (R3) — the hazard gate

    func testUnsafePIDsAreNeverSignaled() {
        let fakes = Fakes()
        // 0 and -1 would make `kill` target a process group / broadcast to every
        // process; 1 is `init`; getpid() is a self-signal. All "supported" yet unsafe.
        fakes.instances = [
            GhosttyInstance(pid: 0, version: "1.3.0"),
            GhosttyInstance(pid: -1, version: "1.3.0"),
            GhosttyInstance(pid: 1, version: "1.3.0"),
            GhosttyInstance(pid: getpid(), version: "1.3.0"),
        ]
        let outcome = fakes.reloader().reload(enabled: true)
        XCTAssertTrue(fakes.sendCalls.isEmpty, "no kill(0)/kill(-1)/kill(1)/self-signal may ever be sent")
        XCTAssertEqual(outcome, .noInstance)
    }

    func testDuplicatePIDsAreDeduped() {
        let fakes = Fakes()
        fakes.instances = [
            GhosttyInstance(pid: 4242, version: "1.3.0"),
            GhosttyInstance(pid: 4242, version: "1.3.0"),
        ]
        let outcome = fakes.reloader().reload(enabled: true)
        XCTAssertEqual(fakes.sendCalls.count, 1, "a duplicate pid is signaled once")
        XCTAssertEqual(outcome, .reloaded(count: 1, skipped: 0))
    }

    // MARK: - Version gate (R4) — never signal an unconfirmed build

    func testConfirmedOldInstanceIsNeverSignaled() {
        let fakes = Fakes()
        fakes.instances = [GhosttyInstance(pid: 4242, version: "1.1.9")]
        let outcome = fakes.reloader().reload(enabled: true)
        XCTAssertEqual(outcome, .versionUnsupported)
        XCTAssertTrue(fakes.sendCalls.isEmpty, "a pre-1.2 Ghostty must never receive SIGUSR2")
    }

    func testUnconfirmableInstanceIsNeverSignaled() {
        let fakes = Fakes()
        fakes.instances = [GhosttyInstance(pid: 4242, version: "")]
        let outcome = fakes.reloader().reload(enabled: true)
        XCTAssertEqual(outcome, .versionUnknown)
        XCTAssertTrue(fakes.sendCalls.isEmpty, "an unconfirmable version must never receive SIGUSR2")
    }

    func testMixedVersionsSignalOnlyTheSupportedInstance() {
        let fakes = Fakes()
        fakes.instances = [
            GhosttyInstance(pid: 100, version: "1.3.0"),
            GhosttyInstance(pid: 200, version: "1.1.0"),
        ]
        let outcome = fakes.reloader().reload(enabled: true)
        XCTAssertEqual(outcome, .reloaded(count: 1, skipped: 1))
        XCTAssertEqual(fakes.signaledPIDs, [100], "only the confirmed 1.3 instance is signaled")
        XCTAssertEqual(outcome.message?.contains("manually"), true,
                       "the skipped older instance must be surfaced for a manual reload")
    }

    func testVersionComparatorMatrix() {
        // True: confirmed >= 1.2.0, including padded/short, numeric (not lexicographic),
        // and suffixed builds.
        for version in ["1.2.0", "1.2", "1.10.0", "2.0.0", "1.2.0-tip+abc", "1.4.0-pre"] {
            XCTAssertTrue(GhosttyReloader.signalReloadSupported(version: version),
                          "\(version) should be supported")
        }
        // False: confirmed older, and anything ambiguous (fail closed — bias to false).
        for version in ["1.1.9", "1.0.0", "1", "", "garbage", "1.2.x", "1..2", "1.1.9-rc1"] {
            XCTAssertFalse(GhosttyReloader.signalReloadSupported(version: version),
                           "\(version) should NOT be supported")
        }
    }

    // MARK: - Per-pid errno classification (R5, R6, KTD6)

    func testVanishedInstanceIsBenign() {
        let fakes = Fakes()
        fakes.instances = [GhosttyInstance(pid: 4242, version: "1.3.0")]
        fakes.errnoByPID[4242] = ESRCH
        let outcome = fakes.reloader().reload(enabled: true)
        XCTAssertEqual(outcome, .noInstance, "ESRCH means the instance vanished — benign, not a failure")
        XCTAssertEqual(fakes.sendCalls.count, 1, "the signal was attempted")
    }

    func testBlockedInstanceIsUnreachable() {
        let fakes = Fakes()
        fakes.instances = [GhosttyInstance(pid: 4242, version: "1.3.0")]
        fakes.errnoByPID[4242] = EPERM
        let outcome = fakes.reloader().reload(enabled: true)
        XCTAssertEqual(outcome, .unreachable, "EPERM is distinct from a vanished instance")
    }

    func testMixedErrnoNeverBecomesFailure() {
        let fakes = Fakes()
        fakes.instances = [
            GhosttyInstance(pid: 10, version: "1.3.0"),   // succeeds (default 0)
            GhosttyInstance(pid: 11, version: "1.3.0"),   // ESRCH
            GhosttyInstance(pid: 12, version: "1.3.0"),   // EPERM
        ]
        fakes.errnoByPID[11] = ESRCH
        fakes.errnoByPID[12] = EPERM
        let outcome = fakes.reloader().reload(enabled: true)
        XCTAssertEqual(outcome, .reloaded(count: 1, skipped: 0),
                       "one success makes the aggregate a (best-effort) reload, never a failure")
    }

    // MARK: - Honest, kit-derived copy (R6, KTD8)

    func testEachOutcomeMessageIsHonestAndDistinct() {
        XCTAssertNil(ReloadOutcome.disabled.message)

        // Routine success stays silent — the user saw "Saved" and auto-reload working is
        // the expected default, so there's nothing worth saying (F2). Single and multi.
        XCTAssertNil(ReloadOutcome.reloaded(count: 1, skipped: 0).message)
        XCTAssertNil(ReloadOutcome.reloaded(count: 2, skipped: 0).message)

        // A skipped instance still needs a manual reload — that part is actionable, so it
        // surfaces a caption saying "manually" (never claiming the reload itself succeeded).
        let withSkip = ReloadOutcome.reloaded(count: 1, skipped: 1).message
        XCTAssertEqual(withSkip?.contains("manually"), true)
        let multiSkip = ReloadOutcome.reloaded(count: 3, skipped: 2).message
        XCTAssertEqual(multiSkip?.contains("2"), true)
        XCTAssertEqual(multiSkip?.contains("manually"), true)

        XCTAssertEqual(ReloadOutcome.noInstance.message?.contains("running"), true)
        XCTAssertEqual(ReloadOutcome.versionUnsupported.message?.contains("1.2"), true)
        XCTAssertEqual(ReloadOutcome.versionUnknown.message?.contains("confirm"), true)
        XCTAssertEqual(ReloadOutcome.unreachable.message?.contains("manually"), true)

        // Every *actionable* outcome must surface a caption; routine success must not.
        for outcome: ReloadOutcome in [.noInstance, .versionUnsupported, .versionUnknown,
                                       .unreachable, .reloaded(count: 1, skipped: 1)] {
            XCTAssertNotNil(outcome.message)
        }
    }
}
