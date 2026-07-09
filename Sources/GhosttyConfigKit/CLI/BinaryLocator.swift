import Foundation

/// Locates the `ghostty` binary by an ordered, absolute-path probe.
///
/// GUI apps launched from Finder do not inherit the shell `PATH`, so a bare
/// `which ghostty` is unreliable. Instead we probe known install locations in
/// priority order, then fall back to asking a login shell. The selection logic
/// is pure and takes injectable probes so it can be unit-tested without touching
/// the real filesystem.
public enum BinaryLocator {

    /// Standard absolute install locations, highest priority first.
    /// - The macOS app bundle (the most common install).
    /// - Apple-silicon Homebrew, then Intel Homebrew.
    public static let standardCandidates: [String] = [
        "/Applications/Ghostty.app/Contents/MacOS/ghostty",
        "/opt/homebrew/bin/ghostty",
        "/usr/local/bin/ghostty",
    ]

    /// The full ordered candidate list, with an optional user override taking
    /// precedence over every standard location.
    public static func candidatePaths(userOverride: String?) -> [String] {
        var paths: [String] = []
        if let override = userOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            paths.append(override)
        }
        paths.append(contentsOf: standardCandidates)
        return paths
    }

    /// Pure selection: returns the first candidate the `isExecutable` probe
    /// accepts, else the login-shell fallback if it too is executable, else nil.
    ///
    /// - Parameters:
    ///   - userOverride: an explicit path the user configured, if any.
    ///   - isExecutable: returns true when the path exists and is executable.
    ///   - shellFallback: returns a path discovered via a login shell, or nil.
    public static func locate(
        userOverride: String?,
        isExecutable: (String) -> Bool,
        shellFallback: () -> String?
    ) -> String? {
        for path in candidatePaths(userOverride: userOverride) where isExecutable(path) {
            return path
        }
        if let fallback = shellFallback()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty, isExecutable(fallback) {
            return fallback
        }
        return nil
    }

    // MARK: - System-backed convenience

    /// Real executability probe against the live filesystem.
    public static func systemIsExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// Asks a login shell for `ghostty` on its `PATH`. This is the last resort
    /// for non-standard installs (e.g., a custom Homebrew prefix or asdf shim).
    ///
    /// Hardening so a hostile environment can't wedge discovery (and the app's
    /// launch):
    ///  - **Non-interactive** login shell (`-lc`, not `-lic`): sources login
    ///    profiles where PATH is normally set, but skips interactive init, which
    ///    can be slow or hang (the exact failure mode this guards against).
    ///  - stderr → `/dev/null` so a noisy profile can't fill an undrained pipe.
    ///  - Fully bounded: the only wait is a `timeout`-second deadline on stdout
    ///    reaching EOF. There is **no** unbounded `waitUntilExit()` — a child that
    ///    lingers after closing stdout must not stall us; the Process reaps itself.
    public static func loginShellFallback(timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v ghostty"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        // Read stdout to EOF on a background queue so the wait can honor a deadline.
        let outFD = pipe.fileHandleForReading.fileDescriptor
        let box = DataBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = readToEOF(fd: outFD)
            done.signal()
        }
        // If stdout hasn't produced output + EOF within the deadline, abandon the
        // probe (kill the shell) rather than risk hanging.
        guard done.wait(timeout: .now() + timeout) == .success else {
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        guard let line = String(data: box.data, encoding: .utf8)?
            .split(separator: "\n").first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !line.isEmpty else {
            return nil
        }
        return line
    }

    /// Read a file descriptor to EOF (POSIX), retrying on EINTR.
    private static func readToEOF(fd: Int32) -> Data {
        var data = Data()
        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, bufferSize) }
            if count > 0 { data.append(buffer, count: count) }
            else if count == 0 { break }
            else if errno == EINTR { continue }
            else { break }
        }
        return data
    }

    /// Locate `ghostty` against the live system, wiring the real probes.
    public static func locateOnSystem(userOverride: String? = nil) -> String? {
        locate(
            userOverride: userOverride,
            isExecutable: systemIsExecutable,
            shellFallback: { loginShellFallback() }
        )
    }
}

/// A lock-guarded `Data` box so the background reader can hand bytes back to the
/// caller across the timeout semaphore.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return _data }
        set { lock.lock(); _data = newValue; lock.unlock() }
    }
}
