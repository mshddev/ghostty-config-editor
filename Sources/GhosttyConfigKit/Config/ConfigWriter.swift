import Foundation

public enum ConfigWriteError: Error, Equatable, Sendable {
    /// The file changed on disk since it was read — refuse rather than clobber (R22).
    case staleOnDisk(path: String)
    case backupFailed(String)
    case stageFailed(String)
    case renameFailed(String)
}

/// The outcome of a successful write, carrying everything needed to undo it (R24).
public struct WriteReceipt: Sendable {
    public let resolvedPath: String
    public let backupURL: URL?
    public let newIdentity: FileIdentity?
    /// The bytes that were on disk before this write (last-write undo, R10/R24).
    public let previousText: String?
}

/// Writes config changes back to disk, treating the target as a symlinked,
/// git-managed dotfile edited by multiple actors (KTD8, R8–R11, R20–R24).
///
/// Two layers:
///  - **Content** — mutate only the model nodes that changed; re-emit every
///    other line verbatim (R8, R11). Pure, no disk.
///  - **Filesystem** — stale-check, out-of-repo backup, same-dir temp + fsync +
///    atomic rename onto the symlink-resolved real path + dir fsync, with
///    permission/encoding fidelity and abort-untouched on any failure.
///
/// Note on R20 ("preserve the inode"): a crash-safe atomic rename necessarily
/// installs a new inode at the path — only an in-place truncate keeps the inode,
/// and that is not crash-safe. We prioritize crash-safety (R21) and the invariant
/// that actually matters for dotfiles: the **symlink is preserved** (never
/// replaced by a regular file) and keeps resolving to the same real path, with
/// permissions/encoding intact. We assert that, not literal inode identity.
public struct ConfigWriter: Sendable {
    public let backupDirectory: URL
    /// Max backups retained per file (R24 bounded retention).
    public let retentionLimit: Int

    public init(backupDirectory: URL = ConfigWriter.defaultBackupDirectory, retentionLimit: Int = 20) {
        self.backupDirectory = backupDirectory
        self.retentionLimit = retentionLimit
    }

    public static var defaultBackupDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("GhosttyConfigManager/Backups", isDirectory: true)
    }

    // MARK: - Content layer (pure)

    /// The file an option write targets: the file where the option already
    /// lives, else the primary config (R8). Multi-file precedence is deferred.
    public func targetFile(forOption name: String, in model: ConfigModel) -> ConfigFile {
        for file in model.allFiles where file.lines.contains(where: { $0.key == name }) {
            return file
        }
        return model.primary
    }

    /// Produce the target file with `name` set to `values` (empty = unset),
    /// changing only the affected lines (AE2, AE3). Repeatable keys reconcile
    /// position-wise so untouched occurrences stay byte-identical.
    public func editedFile(setting name: String, to values: [String], isRepeatable: Bool, in model: ConfigModel) -> ConfigFile {
        let target = targetFile(forOption: name, in: model)
        let newLines = Self.mutate(target.lines, key: name, newValues: values, isRepeatable: isRepeatable)
        return target.replacingLines(newLines)
    }

    static func mutate(_ original: [ConfigLine], key: String, newValues: [String], isRepeatable: Bool) -> [ConfigLine] {
        var lines = original
        let occurrences = lines.indices.filter { lines[$0].key == key }

        if isRepeatable {
            let shared = min(occurrences.count, newValues.count)
            for i in 0..<shared {
                let idx = occurrences[i]
                if lines[idx].value != newValues[i] {
                    lines[idx] = settingLine(key: key, value: newValues[i])
                }
            }
            if newValues.count > occurrences.count {
                let insertAt = (occurrences.last.map { $0 + 1 }) ?? lines.count
                let extras = newValues[occurrences.count...].map { settingLine(key: key, value: $0) }
                lines.insert(contentsOf: extras, at: insertAt)
            } else if newValues.count < occurrences.count {
                for idx in occurrences[newValues.count...].sorted(by: >) {
                    lines.remove(at: idx)
                }
            }
        } else if newValues.isEmpty {
            for idx in occurrences.sorted(by: >) { lines.remove(at: idx) }
        } else if let last = occurrences.last {
            if lines[last].value != newValues[0] {
                lines[last] = settingLine(key: key, value: newValues[0])
            }
        } else {
            lines.append(settingLine(key: key, value: newValues[0]))
        }
        return renumber(lines)
    }

    private static func settingLine(key: String, value: String) -> ConfigLine {
        ConfigLine(raw: "\(key) = \(value)", kind: .setting(key: key, value: value), lineNumber: 0)
    }

    private static func renumber(_ lines: [ConfigLine]) -> [ConfigLine] {
        lines.enumerated().map { ConfigLine(raw: $1.raw, kind: $1.kind, lineNumber: $0 + 1) }
    }

    // MARK: - Filesystem layer

    private static let locks = PathLocks()

    /// Apply an option change and persist it safely in one step.
    @discardableResult
    public func apply(optionName: String, values: [String], isRepeatable: Bool, in model: ConfigModel) throws -> WriteReceipt {
        let edited = editedFile(setting: optionName, to: values, isRepeatable: isRepeatable, in: model)
        return try commit(edited)
    }

    /// Write `newFile` to its resolved real path with the full safety contract.
    @discardableResult
    public func commit(_ newFile: ConfigFile, fileManager: FileManager = .default) throws -> WriteReceipt {
        let realPath = newFile.resolvedPath
        return try Self.locks.withLock(path: realPath) {
            try performCommit(newFile, realPath: realPath, fileManager: fileManager)
        }
    }

    private func performCommit(_ newFile: ConfigFile, realPath: String, fileManager: FileManager) throws -> WriteReceipt {
        // 1. Stale-overwrite guard (R22).
        let current = FileIdentity.capture(path: realPath, fileManager: fileManager)
        if let readStamp = newFile.identity {
            guard let current, current.contentMatches(readStamp) else {
                throw ConfigWriteError.staleOnDisk(path: realPath)
            }
        } else if current != nil {
            // We thought this was a new file, but something created it since.
            throw ConfigWriteError.staleOnDisk(path: realPath)
        }

        let newData = Data(newFile.serialized().utf8)
        let dirURL = URL(fileURLWithPath: realPath).deletingLastPathComponent()

        // 2. Out-of-repo backup of the existing bytes (R24). Abort if it fails.
        var backupURL: URL?
        var previousText: String?
        if let existing = fileManager.contents(atPath: realPath) {
            previousText = String(decoding: existing, as: UTF8.self)
            do {
                backupURL = try makeBackup(of: existing, realPath: realPath, fileManager: fileManager)
            } catch {
                throw ConfigWriteError.backupFailed("\(error)")
            }
        }

        // 3. Stage a temp file in the SAME directory (R21, R23).
        let tempURL = dirURL.appendingPathComponent(".gcm-\(UUID().uuidString).tmp")
        do {
            try newData.write(to: tempURL)
            let perms = newFile.identity?.permissions ?? 0o644
            try? fileManager.setAttributes([.posixPermissions: NSNumber(value: perms)], ofItemAtPath: tempURL.path)
            Self.copyExtendedAttributes(from: realPath, to: tempURL.path)
            Self.fsyncPath(tempURL.path)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw ConfigWriteError.stageFailed("\(error)")
        }

        // 4. Atomic rename onto the resolved real path (R20, R21). The symlink at
        //    the original path — if any — keeps pointing here, still a symlink.
        guard rename(tempURL.path, realPath) == 0 else {
            let err = String(cString: strerror(errno))
            try? fileManager.removeItem(at: tempURL)
            throw ConfigWriteError.renameFailed(err)
        }
        // 5. fsync the directory so the rename is durable.
        Self.fsyncPath(dirURL.path)

        return WriteReceipt(
            resolvedPath: realPath,
            backupURL: backupURL,
            newIdentity: FileIdentity.capture(path: realPath, fileManager: fileManager),
            previousText: previousText
        )
    }

    /// Restore the bytes captured in a receipt (last-write undo, R10). Writes via
    /// the same atomic mechanism; skips the stale check since this is a revert.
    @discardableResult
    public func restore(from receipt: WriteReceipt, fileManager: FileManager = .default) throws -> Bool {
        guard let previous = receipt.previousText else { return false }
        let realPath = receipt.resolvedPath
        return try Self.locks.withLock(path: realPath) {
            let dirURL = URL(fileURLWithPath: realPath).deletingLastPathComponent()
            let tempURL = dirURL.appendingPathComponent(".gcm-\(UUID().uuidString).tmp")
            try Data(previous.utf8).write(to: tempURL)
            Self.fsyncPath(tempURL.path)
            guard rename(tempURL.path, realPath) == 0 else {
                try? fileManager.removeItem(at: tempURL)
                throw ConfigWriteError.renameFailed(String(cString: strerror(errno)))
            }
            Self.fsyncPath(dirURL.path)
            return true
        }
    }

    /// Remove orphaned write temps left behind by a crashed prior write (crash
    /// recovery, KTD8). Safe to call at launch: a live write holds the path lock,
    /// and at startup there is no concurrent write in flight.
    public func sweepStaleTempFiles(inDirectoryOf path: String, fileManager: FileManager = .default) {
        let dir = (ConfigReader.canonicalPath(path) as NSString).deletingLastPathComponent
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { return }
        for name in entries where name.hasPrefix(".gcm-") && name.hasSuffix(".tmp") {
            try? fileManager.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
        }
    }

    // MARK: - Backups (R24)

    private func makeBackup(of data: Data, realPath: String, fileManager: FileManager) throws -> URL {
        let dir = backupDirectory.appendingPathComponent(Self.backupFolderName(for: realPath), isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).bak"
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        pruneBackups(in: dir, fileManager: fileManager)
        return url
    }

    private func pruneBackups(in dir: URL, fileManager: FileManager) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        guard entries.count > retentionLimit else { return }
        let sorted = entries.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return l < r
        }
        for url in sorted.prefix(sorted.count - retentionLimit) {
            try? fileManager.removeItem(at: url)
        }
    }

    static func backupFolderName(for path: String) -> String {
        // A filesystem-safe, collision-resistant folder per real path.
        let base = (path as NSString).lastPathComponent
        let digest = String(UInt64(bitPattern: Int64(path.hashValue)), radix: 16)
        return "\(base)-\(digest)"
    }

    // MARK: - POSIX helpers

    private static func fsyncPath(_ path: String) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }

    static func copyExtendedAttributes(from src: String, to dst: String) {
        let listSize = listxattr(src, nil, 0, 0)
        guard listSize > 0 else { return }
        var names = [CChar](repeating: 0, count: listSize)
        let got = listxattr(src, &names, listSize, 0)
        guard got > 0 else { return }
        names.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < got {
                let name = String(cString: base.advanced(by: offset))
                if name.isEmpty { break }
                let valueSize = getxattr(src, name, nil, 0, 0, 0)
                if valueSize > 0 {
                    var value = [UInt8](repeating: 0, count: valueSize)
                    if getxattr(src, name, &value, valueSize, 0, 0) >= 0 {
                        _ = setxattr(dst, name, value, valueSize, 0, 0)
                    }
                }
                offset += name.utf8.count + 1
            }
        }
    }
}

/// Per-path in-process lock so two windows (or a double-apply) can't race on the
/// same file (KTD8). Belt-and-suspenders for a single-window app, but cheap.
final class PathLocks: @unchecked Sendable {
    private let master = NSLock()
    private var locks: [String: NSRecursiveLock] = [:]

    func withLock<T>(path: String, _ body: () throws -> T) rethrows -> T {
        master.lock()
        let lock = locks[path] ?? {
            let new = NSRecursiveLock()
            locks[path] = new
            return new
        }()
        master.unlock()
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
