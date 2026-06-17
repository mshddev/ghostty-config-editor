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
    /// No `ghostty` binary could be located by the probe (R19).
    case binaryNotFound
    /// The binary was found but `+version` did not parse / verify (R19).
    case versionUnverified(String)
    /// The subprocess could not be launched.
    case launchFailed(String)
    /// The subprocess outlived its deadline and was terminated.
    case timedOut
}

/// Runs `ghostty` subcommands, capturing stdout/stderr asynchronously.
///
/// Uses `Foundation.Process` with **concurrent** pipe draining (KTD4 fallback):
/// verbose output such as `+show-config --default --docs` (~176 KB here) would
/// deadlock a naive read-then-wait because the child blocks once the 64 KB pipe
/// buffer fills. Reading stdout and stderr concurrently before awaiting exit
/// avoids that. `swift-subprocess` is the intended future swap; this dependency-
/// free path is the documented fallback and keeps the build hermetic.
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

        // Watchdog: if the child outlives the deadline, kill it. Killing closes
        // its pipe write-ends, so the drains below hit EOF and we unwind instead
        // of blocking forever. `Process` is not Sendable, so the watchdog touches
        // only the pid via POSIX `kill` (signal 0 = liveness probe).
        let pid = process.processIdentifier
        let timedOut = AtomicFlag()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard kill(pid, 0) == 0 else { return } // already exited
            timedOut.set()
            kill(pid, SIGTERM)
            try? await Task.sleep(for: .milliseconds(500))
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }

        async let outData = Self.drain(fd: outFD)
        async let errData = Self.drain(fd: errFD)
        let (out, err) = await (outData, errData)

        // Both pipes hit EOF, so the child has closed its write ends and is
        // exiting; this returns promptly.
        process.waitUntilExit()
        watchdog.cancel()

        if timedOut.isSet { throw GhosttyCLIError.timedOut }
        return CLIResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
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

    /// Drain a file descriptor to EOF on a background queue, bridged to async.
    /// Reads raw bytes (fd is Sendable) so nothing non-Sendable crosses the
    /// continuation boundary under Swift 6 concurrency checking.
    private static func drain(fd: Int32) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var data = Data()
                let bufferSize = 65_536
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, bufferSize) }
                    if count > 0 {
                        data.append(buffer, count: count)
                    } else if count == 0 {
                        break // EOF
                    } else if errno == EINTR {
                        continue // interrupted by a signal — retry, don't truncate
                    } else {
                        break // genuine read error
                    }
                }
                continuation.resume(returning: data)
            }
        }
    }
}

/// A located and version-verified Ghostty installation (R18, R19).
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

/// A one-way Sendable boolean: set from the timeout watchdog Task, read by the
/// caller after the subprocess unwinds.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
