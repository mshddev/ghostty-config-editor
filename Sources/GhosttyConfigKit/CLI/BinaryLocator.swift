import Foundation

/// Locates the `ghostty` binary by an ordered, absolute-path probe (KTD3).
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
    public static func loginShellFallback() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v ghostty"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let line = String(data: data, encoding: .utf8)?
            .split(separator: "\n").first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !line.isEmpty else {
            return nil
        }
        return line
    }

    /// Locate `ghostty` against the live system, wiring the real probes.
    public static func locateOnSystem(userOverride: String? = nil) -> String? {
        locate(
            userOverride: userOverride,
            isExecutable: systemIsExecutable,
            shellFallback: loginShellFallback
        )
    }
}
