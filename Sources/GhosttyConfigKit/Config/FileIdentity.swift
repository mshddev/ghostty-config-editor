import Foundation
import CryptoKit

/// A snapshot of a config file's on-disk identity, captured at read time and
/// re-checked at write time to detect external changes (R22) and to preserve
/// attributes through a write (R23).
public struct FileIdentity: Sendable, Equatable {
    public let resolvedPath: String
    public let inode: UInt64
    public let size: Int64
    public let modifiedAt: Date
    /// SHA-256 of the file's bytes — the authoritative "did it change" signal.
    public let sha256: String
    /// `st_mode & 0o7777` — permission bits to carry onto the rewritten file.
    public let permissions: UInt16

    public init(resolvedPath: String, inode: UInt64, size: Int64, modifiedAt: Date, sha256: String, permissions: UInt16) {
        self.resolvedPath = resolvedPath
        self.inode = inode
        self.size = size
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
        self.permissions = permissions
    }

    /// Capture the identity of the file at `path` (after resolving symlinks).
    /// Returns nil when the file does not exist.
    public static func capture(path: String, fileManager: FileManager = .default) -> FileIdentity? {
        let resolved = ConfigReader.canonicalPath(path)
        var info = stat()
        guard stat(resolved, &info) == 0 else { return nil }
        guard let data = fileManager.contents(atPath: resolved) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let mtime = Date(timeIntervalSince1970:
            Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileIdentity(
            resolvedPath: resolved,
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedAt: mtime,
            sha256: digest,
            permissions: UInt16(info.st_mode & 0o7777)
        )
    }

    /// True when the on-disk content is byte-identical (the only signal that
    /// matters for stale-overwrite detection; mtime alone is unreliable).
    public func contentMatches(_ other: FileIdentity) -> Bool {
        sha256 == other.sha256
    }
}
