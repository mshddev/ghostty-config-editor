import XCTest
@testable import GhosttyConfigKit

/// U1 (GAP-8): the `SerialWriteQueue` contract — one write in flight, tail-only
/// same-key coalescing, FIFO for everything else, and each entry fully resolved
/// before the next starts. Receipt / stale-on-disk / byte-fidelity semantics stay
/// `ConfigWriterTests`' responsibility; these assert only queue ordering + the fact
/// that serialization removes the self-inflicted stale-on-disk race.
///
/// Every test is deterministic: a "blocker" entry parks the executor while the
/// scenario's entries are staged with the fire-and-forget `enqueue`, then a release
/// signal drains them. No sleeps, no polling.
final class ApplySerializationTests: XCTestCase {

    // MARK: - Coalescing

    func testTwoRapidSameKeySubmissionsCoalesceToLaterValueInPlace() async {
        let queue = SerialWriteQueue()
        let rec = Recorder()
        let started = SignalOnce(), release = SignalOnce(), done = SignalOnce()

        await queue.enqueue(key: "blocker") { await started.fire(); await release.wait(); await rec.record("blocker") }
        await started.wait()   // blocker is now executing; the pair below piles up in `pending`

        await queue.enqueue(key: "x") { await rec.record("x=1") }
        await queue.enqueue(key: "x") { await rec.record("x=2"); await done.fire() }

        await release.fire()
        await done.wait()

        // One x execution (x=1 never ran), the later value, in x's original slot
        // (immediately after the blocker where the pending x lived).
        let events = await rec.events
        XCTAssertEqual(events, ["blocker", "x=2"])
    }

    func testSameKeyCoalesceNeverReordersPastInterposedNonCoalescableEntry() async {
        let queue = SerialWriteQueue()
        let rec = Recorder()
        let started = SignalOnce(), release = SignalOnce(), done = SignalOnce()

        await queue.enqueue(key: "blocker") { await started.fire(); await release.wait() }
        await started.wait()

        await queue.enqueue(key: "x") { await rec.record("x=1") }
        await queue.enqueue(key: nil) { await rec.record("undo") }          // interposed, non-coalescable
        await queue.enqueue(key: "x") { await rec.record("x=2"); await done.fire() }

        await release.fire()
        await done.wait()

        // x=2 must NOT merge into x=1's slot (tail is `undo`, not `x`): merging would drop
        // x=1 and jump the undo. It appends after undo instead.
        let events = await rec.events
        XCTAssertEqual(events, ["x=1", "undo", "x=2"])
    }

    // MARK: - Ordering

    func testDistinctKeysExecuteFIFO() async {
        let queue = SerialWriteQueue()
        let rec = Recorder()
        let started = SignalOnce(), release = SignalOnce(), done = SignalOnce()

        await queue.enqueue(key: "blocker") { await started.fire(); await release.wait() }
        await started.wait()

        await queue.enqueue(key: "a") { await rec.record("a") }
        await queue.enqueue(key: "b") { await rec.record("b") }
        await queue.enqueue(key: "c") { await rec.record("c"); await done.fire() }

        await release.fire()
        await done.wait()

        let events = await rec.events
        XCTAssertEqual(events, ["a", "b", "c"])
    }

    func testUndoBehindAPendingWriteExecutesAgainstPostWriteState() async {
        let queue = SerialWriteQueue()
        let rec = Recorder()
        let state = MutableState()
        let started = SignalOnce(), release = SignalOnce(), done = SignalOnce()

        await queue.enqueue(key: "blocker") { await started.fire(); await release.wait() }
        await started.wait()

        // A write mutates shared state...
        await queue.enqueue(key: "opt") { await state.set("written"); await rec.record("write") }
        // ...and an undo enqueued behind it reads that state at EXECUTION time. If the
        // undo had snapshotted state at enqueue it would see "initial", restoring stale bytes.
        await queue.enqueue(key: nil) {
            let seen = await state.get()
            await rec.record("undo-saw-\(seen)")
            await done.fire()
        }

        await release.fire()
        await done.wait()

        let events = await rec.events
        XCTAssertEqual(events, ["write", "undo-saw-written"])
    }

    // MARK: - Serialization (never concurrent)

    func testEntriesExecuteSeriallyNeverConcurrently() async {
        // Covers "an applyEdit and a batch reset submitted together execute serially":
        // nil keys stand in for non-coalescable batch/undo entries, distinct keys for
        // single-option applies. None coalesce, so all N run and overlap would show.
        let queue = SerialWriteQueue()
        let detector = OverlapDetector()
        let done = SignalOnce()
        let n = 12
        let counter = Counter(target: n, done: done)

        for i in 0..<n {
            let key: String? = (i % 2 == 0) ? nil : "k\(i)"
            await queue.enqueue(key: key) {
                await detector.enter()
                await Task.yield()   // invite overlap if serialization were broken
                await Task.yield()
                await detector.leave()
                await counter.inc()
            }
        }

        await done.wait()
        let maxObserved = await detector.maxObserved
        XCTAssertEqual(maxObserved, 1, "writes must never overlap")
    }

    // MARK: - End-to-end against a real temp file (no live binary; cli == nil skips validation)

    func testRapidSameOptionEditsCoalesceToLaterValueOnDisk() async throws {
        let (dir, path) = try Self.makeTempConfig("font-size = 12\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = ConfigWriter(backupDirectory: dir.appendingPathComponent("backups"))
        let errors = ErrorBox()

        let queue = SerialWriteQueue()
        let started = SignalOnce(), release = SignalOnce(), done = SignalOnce()
        await queue.enqueue(key: "blocker") { await started.fire(); await release.wait() }
        await started.wait()

        // Each write reads a FRESH model from disk (mirrors performApplyEdit). Piled up
        // behind the blocker, they coalesce to the last value.
        await queue.enqueue(key: "font-size", work: Self.write("13", to: path, writer: writer, errors: errors))
        await queue.enqueue(key: "font-size", work: Self.write("14", to: path, writer: writer, errors: errors))
        await queue.enqueue(key: "font-size") {
            await Self.write("15", to: path, writer: writer, errors: errors)()
            await done.fire()
        }

        await release.fire()
        await done.wait()

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "font-size = 15\n")
        let caught = await errors.all
        XCTAssertTrue(caught.isEmpty, "no write should fail; got \(caught)")
    }

    func testConcurrentDistinctOptionWritesSerializeWithoutStaleOnDisk() async throws {
        // The actual bug U1 fixes: unserialized, each write read the same pre-refresh model
        // and the second to commit saw the file "changed on disk". Serialized + fresh reads,
        // every write lands and none stale-fails.
        let (dir, path) = try Self.makeTempConfig("font-size = 12\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = ConfigWriter(backupDirectory: dir.appendingPathComponent("backups"))
        let errors = ErrorBox()

        let queue = SerialWriteQueue()
        let done = SignalOnce()
        let edits: [(String, String)] = [
            ("font-size", "20"), ("cursor-style", "bar"), ("window-save-state", "always"),
            ("scrollback-limit", "1000"), ("mouse-hide-while-typing", "true"),
        ]
        let counter = Counter(target: edits.count, done: done)

        for (key, value) in edits {
            await queue.enqueue(key: key) {
                await Self.write(value, forKey: key, to: path, writer: writer, errors: errors)()
                await counter.inc()
            }
        }

        await done.wait()

        let caught = await errors.all
        XCTAssertTrue(caught.isEmpty, "no write should stale-fail once serialized; got \(caught)")
        let final = try String(contentsOfFile: path, encoding: .utf8)
        for (key, value) in edits {
            XCTAssertTrue(final.contains("\(key) = \(value)"), "expected \(key) = \(value) in:\n\(final)")
        }
    }

    // MARK: - Helpers

    private static func makeTempConfig(_ contents: String) throws -> (dir: URL, path: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gcm-u1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config").path
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return (dir, path)
    }

    /// A work closure that reads the current config fresh, sets `font-size` to `value`,
    /// and commits — capturing any thrown error into `errors`.
    private static func write(_ value: String, to path: String, writer: ConfigWriter, errors: ErrorBox) -> @Sendable () async -> Void {
        write(value, forKey: "font-size", to: path, writer: writer, errors: errors)
    }

    private static func write(_ value: String, forKey key: String, to path: String, writer: ConfigWriter, errors: ErrorBox) -> @Sendable () async -> Void {
        {
            do {
                let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                var file = ConfigFile.parse(text: text, path: path, resolvedPath: path)
                file.identity = FileIdentity.capture(path: path)
                let model = ConfigModel(primary: file)
                _ = try await writer.validateAndApply(optionName: key, values: [value], isRepeatable: false, in: model, cli: nil)
            } catch {
                await errors.add(error)
            }
        }
    }
}

// MARK: - Deterministic test primitives

/// A one-shot broadcast signal: `wait()` suspends until the first `fire()`.
private actor SignalOnce {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func fire() {
        guard !fired else { return }
        fired = true
        let resume = waiters
        waiters.removeAll()
        for continuation in resume { continuation.resume() }
    }
    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Ordered event log written from work closures.
private actor Recorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

/// Fires `done` once `inc()` has been called `target` times.
private actor Counter {
    private var count = 0
    private let target: Int
    private let done: SignalOnce
    init(target: Int, done: SignalOnce) { self.target = target; self.done = done }
    func inc() async {
        count += 1
        if count == target { await done.fire() }
    }
}

/// Tracks the maximum number of work closures executing at once.
private actor OverlapDetector {
    private var current = 0
    private(set) var maxObserved = 0
    func enter() { current += 1; maxObserved = max(maxObserved, current) }
    func leave() { current -= 1 }
}

/// Shared mutable state a write can set and a later undo can read.
private actor MutableState {
    private var value = "initial"
    func set(_ newValue: String) { value = newValue }
    func get() -> String { value }
}

/// Collects errors thrown inside work closures.
private actor ErrorBox {
    private(set) var all: [Error] = []
    func add(_ error: Error) { all.append(error) }
}
