import Foundation

/// The result of running a `ghostty` subcommand.
public struct CLIResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }
}

/// Errors surfaced by the CLI layer.
public enum GhosttyCLIError: Error, Equatable, Sendable {
    /// No `ghostty` binary could be located by the probe.
    case binaryNotFound
    /// The binary was found but `+version` did not parse / verify.
    case versionUnverified(String)
    /// The subprocess could not be launched.
    case launchFailed(String)
    /// The subprocess outlived its deadline and was terminated.
    case timedOut
}

/// Runs `ghostty` subcommands, capturing stdout/stderr asynchronously.
///
/// Uses `Foundation.Process` with **concurrent, deadline-bounded** pipe draining
/// (fallback):
///  - Verbose output such as `+show-config --default --docs` (~176 KB here) would
///    deadlock a naive read-then-wait because the child blocks once the 64 KB
///    pipe buffer fills. Reading stdout and stderr concurrently avoids that.
///  - Draining to **EOF alone is unsafe**: if the child leaks its write-end to a
///    lingering helper the pipe never closes, so a blocking read-to-EOF hangs
///    forever (this is what intermittently wedged the test suite — the pid-only
///    watchdog can't force EOF). The drains are therefore **non-blocking and
///    bounded by an absolute deadline**, so a wedged or FD-leaking child yields
///    `.timedOut` and never blocks the caller.
///
/// `swift-subprocess` is the intended future swap; this dependency-free path is
/// the documented fallback and keeps the build hermetic.
public struct GhosttyCLI: Sendable {
    public let binaryPath: String

    public init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    /// Run a subcommand (e.g., `["+version"]`) and capture its output. A binary
    /// that wedges is terminated after `timeout` seconds and surfaces `.timedOut`
    /// rather than hanging the caller (and the app) forever.
    public func run(_ arguments: [String], timeout: TimeInterval = 30) async throws -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Capture descriptors (Int32 is Sendable) before crossing thread
        // boundaries; the Pipe objects stay alive via the Process for the
        // duration of this call.
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor

        do {
            try process.run()
        } catch {
            throw GhosttyCLIError.launchFailed(error.localizedDescription)
        }

        // `Process` is not Sendable, so the timeout path touches only the pid via
        // POSIX `kill` (signal 0 = liveness probe).
        let pid = process.processIdentifier

        // Drain both pipes concurrently, bounded by an absolute deadline rather
        // than by EOF (see the type doc): a child that never closes its write-end
        // — or leaks it to a helper — stops the read at the deadline instead of
        // hanging the caller and, in tests, the whole suite.
        let deadline = DispatchTime.now() + timeout
        async let outResult = Self.drain(fd: outFD, deadline: deadline)
        async let errResult = Self.drain(fd: errFD, deadline: deadline)
        let (out, err) = await (outResult, errResult)

        if out.hitDeadline || err.hitDeadline {
            // The child outlived its deadline: force it down (escalating to
            // SIGKILL off the hot path so teardown never blocks this call) and
            // surface a timeout rather than reporting a partial run.
            kill(pid, SIGTERM)
            Task.detached {
                try? await Task.sleep(for: .milliseconds(500))
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
            throw GhosttyCLIError.timedOut
        }

        // Both pipes hit EOF within the deadline, so the child has closed its
        // write ends and is exiting; this returns promptly.
        process.waitUntilExit()
        return CLIResult(stdout: out.data, stderr: err.data, exitCode: process.terminationStatus)
    }

    /// Run `+version` and return the parsed version string (e.g., "1.3.1").
    public func version() async throws -> String {
        let result = try await run(["+version"])
        guard let version = Self.parseVersion(result.stdoutString) else {
            throw GhosttyCLIError.versionUnverified(result.stdoutString)
        }
        return version
    }

    /// Parse the version number from `+version` output. The first line is
    /// "Ghostty <version>" possibly followed by build metadata lines.
    public static func parseVersion(_ output: String) -> String? {
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("ghostty") else { continue }
            let remainder = line.dropFirst("ghostty".count).trimmingCharacters(in: .whitespaces)
            // Take the first whitespace-delimited token that looks like a version.
            if let token = remainder.split(separator: " ").first,
               token.first?.isNumber == true {
                return String(token)
            }
        }
        return nil
    }

    // MARK: - Concurrent drain

    /// One pipe's drained bytes plus whether the read stopped at the deadline
    /// (rather than EOF) — the caller's timeout signal.
    private struct DrainResult: Sendable {
        let data: Data
        let hitDeadline: Bool
    }

    /// Drain a file descriptor until EOF *or* `deadline`, whichever comes first,
    /// on a background queue bridged to async. Uses **non-blocking** reads so a
    /// child that never closes its write-end (or leaks it to a helper) cannot
    /// wedge the read past the deadline — the loop always terminates. Reads raw
    /// bytes (fd is Sendable) so nothing non-Sendable crosses the continuation
    /// boundary under Swift 6 concurrency checking.
    private static func drain(fd: Int32, deadline: DispatchTime) async -> DrainResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<DrainResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // Non-blocking so a stalled child surfaces as EAGAIN we can poll
                // against the deadline, instead of parking forever inside read().
                let flags = fcntl(fd, F_GETFL)
                if flags != -1 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

                var data = Data()
                let bufferSize = 65_536
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                var hitDeadline = false
                while true {
                    if DispatchTime.now() >= deadline { hitDeadline = true; break }
                    let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, bufferSize) }
                    if count > 0 {
                        data.append(buffer, count: count)
                    } else if count == 0 {
                        break // EOF: the child closed this write end
                    } else if errno == EAGAIN || errno == EWOULDBLOCK {
                        usleep(5_000) // nothing available yet; back off (bounded by the deadline)
                    } else if errno == EINTR {
                        continue // interrupted by a signal — retry, don't truncate
                    } else {
                        break // genuine read error
                    }
                }
                continuation.resume(returning: DrainResult(data: data, hitDeadline: hitDeadline))
            }
        }
    }
}

/// A located and version-verified Ghostty installation.
public struct GhosttyEnvironment: Sendable {
    public let cli: GhosttyCLI
    public let version: String
    public var binaryPath: String { cli.binaryPath }

    /// Locate the binary, then verify it by parsing `+version`. Throws a typed
    /// error the UI can turn into a clear not-found / unsupported state rather
    /// than crashing.
    public static func discover(userOverride: String? = nil) async throws -> GhosttyEnvironment {
        guard let path = BinaryLocator.locateOnSystem(userOverride: userOverride) else {
            throw GhosttyCLIError.binaryNotFound
        }
        let cli = GhosttyCLI(binaryPath: path)
        let version = try await cli.version()
        return GhosttyEnvironment(cli: cli, version: version)
    }
}
