---
title: "Directory-walk loop hangs forever where URL.deletingLastPathComponent cycles at the filesystem root"
date: 2026-06-17
category: docs/solutions/logic-errors/
module: GhosttyConfigKit
problem_type: logic_error
component: tooling
symptoms:
  - "CI test step hung ~12 min then exited 1 with no assertion failure — passed locally in ~2s"
  - "CI log showed only ~70 of 119 tests; measured time ~1.3s but ~12 min of wall-clock vanished in one test"
  - "The hang was pure-CPU with no I/O, so it spun silently with no output"
  - "Block-buffered piped stdout hid the true hanging test and misdirected the investigation twice"
root_cause: logic_error
resolution_type: code_fix
severity: high
related_components:
  - BinaryLocator
  - ThemeProvider
  - ci-workflow
tags:
  - infinite-loop
  - foundation
  - url-path
  - nsstring
  - ci-hang
  - swift
  - cross-platform
  - stdout-buffering
---

# Directory-walk loop hangs forever where URL.deletingLastPathComponent cycles at the filesystem root

## Problem

`GitContext.isInsideWorkingTree(path:)` could enter an **infinite loop** while walking up the directory tree to find a `.git` directory. The loop relied on `URL.deletingLastPathComponent()` reaching a stable fixed point at the filesystem root, but that behavior is Foundation-version-dependent. On the CI runner (macos-15 / Xcode 16 / Swift 6) the URL cycled between `/` and `/..` instead of converging on `/`, so the root-detection check never fired and the function spun forever on CPU.

Because `isInsideWorkingTree` runs in the **shipped app after every config apply**, this was not merely a CI problem — it could hang the app for real users on affected environments. It first surfaced as a CI hang in PR #1, the project's first CI workflow (`swift build` + `swift test`).

## Symptoms

- CI "Test" step **hung ~12 minutes** every run, then exited 1 — no assertion failure in the log, just a hang.
- **Locally the full 119-test suite passed in ~2s**; the bug never reproduced on the dev machine (macOS 26).
- CI log showed only ~70 of 119 test results before stalling.
- Measured cumulative test time ~1.3s versus ~12 min wall-clock — the gap was pure CPU spinning, no I/O.
- The hang occurred in `ConfigWriterTests.testGitContextDetectsWorkingTree`.

## What Didn't Work

1. **Shell-probe theory (wrong root cause).** The first suspect was the 6 ghostty-requiring tests, which call `BinaryLocator.locateOnSystem()` → a real `zsh -lic` login-shell probe, assumed to be slow or hanging on CI. We hardened `loginShellFallback` (switched to non-interactive `-lc`, redirected stderr to `/dev/null`, removed an unbounded `process.waitUntilExit()`) and pointed the tests at a fast `BinaryLocator.locateForTests()` that skips the shell probe entirely. Re-ran CI → **still hung ~12 min at the same point.** The shell probe was not the cause (though the unbounded `waitUntilExit()` was a genuine latent bug worth fixing anyway).

2. **Concurrency-test theory (wrong root cause).** A new concurrency test used `Task.detached` plus a blocking `usleep`, suspected of starving Swift's cooperative thread pool. Line-buffered output later proved that test **never even ran** — the hang happened earlier in the suite.

3. **Trusting the CI log's "last test" (misleading evidence).** stdout to a CI pipe is **block-buffered**, so the log only showed the last flushed 4–8 KB chunk. The apparent "last test" in the log was not the actual hang location. This misdirection sent the investigation down the wrong path twice.

The diagnostic that finally worked: run the test step under a **PTY** to force line-buffered output, plus a job timeout to fail fast.

```yaml
    timeout-minutes: 12
    steps:
      - name: Test
        run: script -q /dev/null swift test   # PTY -> line-buffered -> reliable hang location
```

With line buffering, the log reliably stopped at the hanging test, pinpointing `GitContext.isInsideWorkingTree`.

## Solution

Replace `URL`-based path math (whose root fixed point is Foundation-version-dependent) with **`NSString` path math** (which converges predictably), and add an explicit no-progress guard so the loop can never spin even if path semantics shift again.

```swift
// Sources/GhosttyConfigKit/Config/GitContext.swift — BEFORE (buggy)
public static func isInsideWorkingTree(path: String, fileManager: FileManager = .default) -> Bool {
    var directory = URL(fileURLWithPath: ConfigReader.canonicalPath(path)).deletingLastPathComponent()
    while true {
        if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            return true
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { return false } // FRAGILE root fixed-point
        directory = parent
    }
}
```

```swift
// AFTER (fixed)
public static func isInsideWorkingTree(path: String, fileManager: FileManager = .default) -> Bool {
    var dir = (ConfigReader.canonicalPath(path) as NSString).deletingLastPathComponent
    while !dir.isEmpty {
        if fileManager.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
            return true
        }
        if dir == "/" { return false }            // reached the filesystem root
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir { return false }          // no upward progress — stop
        dir = parent
    }
    return false
}
```

After the fix (and reverting CI to plain `swift test` for a reliable exit code, keeping `timeout-minutes` as a fast-fail guard): **CI green — build + 119 tests in 41 seconds.**

## Why This Works

- `NSString.deletingLastPathComponent` converges **predictably** on `/` and stops there, instead of cycling `/` ↔ `/..` the way `URL.deletingLastPathComponent()` did on the CI runner's Foundation. This removes the version-dependent behavior that caused the divergence between local and CI.
- Termination is guaranteed by the **no-upward-progress guard** (`if parent == dir`): each iteration must move strictly toward the root or the loop stops, so it cannot spin even if path semantics shift again. The explicit `if dir == "/"` is a conventional, readable early return for the common root case — not a second safety mechanism (the progress guard already subsumes it), and `while !dir.isEmpty` rejects degenerate empty input.
- The bug was pure CPU with no I/O, which is exactly why it presented as an unexplained multi-minute hang with a fast measured test time; deterministic termination eliminates the spin entirely.

## Prevention

- **Don't rely on `URL.deletingLastPathComponent()` reaching a stable root fixed point.** Its behavior at `/` is Foundation-version-dependent (locally converged on `/`, on CI cycled `/` ↔ `/..`). Use `NSString` path math, and/or cap iterations or assert strict upward progress so a directory-walk loop can never spin.
- **Add a CI job `timeout-minutes`** so a hang fails fast instead of burning ~12 minutes per run.
- **Force line-buffered output to locate hangs.** CI pipes are block-buffered, so the log's apparent "last line" lies. Run the step under a PTY (`script -q /dev/null swift test`) to get reliable line-buffered output that stops at the true hang location. Once diagnosed, revert to plain `swift test` for a clean exit code and keep the timeout.
- **No unbounded `process.waitUntilExit()` in subprocess probes.** In `loginShellFallback`, a read-only timeout didn't guard the process reap, so a lingering shell on a slow `.zshrc` could still hang the *shipped app*. Remove the unbounded wait and prefer a non-interactive login shell (`-lc`, not `-lic`).
- **Don't run blocking I/O on the cooperative pool via `Task.detached`.** `Task.detached` still runs on Swift's fixed-size cooperative executor, so blocking I/O there can starve the pool on a low-core runner. In `ThemeProvider.colors(for:)`, the blocking `loadFile` was moved off `Task.detached` onto a `DispatchQueue.global` continuation bridge (matching `GhosttyCLI.drain`), since a Dispatch queue grows threads on demand.

## Related

- `Sources/GhosttyConfigKit/Config/GitContext.swift` — the fix.
- `Sources/GhosttyConfigKit/CLI/BinaryLocator.swift` (`loginShellFallback`) and `Sources/GhosttyConfigKit/Themes/ThemeParser.swift` (`ThemeProvider.colors`) — the two hardening fixes from the same investigation.
- `.github/workflows/ci.yml` — added the `timeout-minutes` fast-fail guard.
