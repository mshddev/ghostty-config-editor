import Foundation
import CryptoKit

public enum ConfigWriteError: Error, Equatable, Sendable {
    /// The file changed on disk since it was read — refuse rather than clobber (R22).
    case staleOnDisk(path: String)
    /// The proposed config failed `+validate-config`; nothing was written (R15).
    case validationFailed([ValidationMessage])
    case backupFailed(String)
    case stageFailed(String)
    case renameFailed(String)
    /// A key or value contained a newline — writing it would split into extra
    /// config directives (e.g. an injected `config-file`), so it is refused (R8).
    case invalidValue(String)
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
        return base.appendingPathComponent("GhosttyConfigEditor/Backups", isDirectory: true)
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
        let newLines = Self.mutate(target.lines, key: name, newValues: values,
                                   isRepeatable: isRepeatable, lineEnding: target.lineEnding)
        return target.replacingLines(newLines)
    }

    /// One mutation in a batched edit: set `key` to `values` (empty = unset). Repeatable
    /// keys reconcile position-wise like the single-option path.
    public struct BatchOperation: Sendable, Equatable {
        public let key: String
        public let values: [String]
        public let isRepeatable: Bool
        public init(key: String, values: [String], isRepeatable: Bool) {
            self.key = key
            self.values = values
            self.isRepeatable = isRepeatable
        }

        /// An "unset this option" op (reset-to-default), the batch's main use (KTD5).
        public static func unset(_ key: String, isRepeatable: Bool) -> BatchOperation {
            BatchOperation(key: key, values: [], isRepeatable: isRepeatable)
        }
    }

    /// Fold several mutations into the **primary** file's lines in one pass and return the
    /// edited primary (KTD5). Unlike looping `editedFile(setting:)` — which retargets and
    /// commits per call, yielding N backups / N validations / N reloads and a depth-1 undo
    /// that reverts only the last op — this produces one file so a single `commit` gives one
    /// backup / one validation / one receipt (hence one ⌘Z reverts the whole batch).
    /// Operates on the primary alone (options living in `config-file` includes are left
    /// untouched — the safe choice, never rewriting a file the batch doesn't own).
    public func editedFile(applying operations: [BatchOperation], in model: ConfigModel) -> ConfigFile {
        var lines = model.primary.lines
        for op in operations {
            lines = Self.mutate(lines, key: op.key, newValues: op.values,
                                isRepeatable: op.isRepeatable, lineEnding: model.primary.lineEnding)
        }
        return model.primary.replacingLines(lines)
    }

    static func mutate(_ original: [ConfigLine], key: String, newValues: [String], isRepeatable: Bool, lineEnding: String = "\n") -> [ConfigLine] {
        var lines = original
        let occurrences = lines.indices.filter { lines[$0].key == key }

        if isRepeatable {
            let shared = min(occurrences.count, newValues.count)
            for i in 0..<shared {
                let idx = occurrences[i]
                if lines[idx].value != newValues[i] {
                    lines[idx] = settingLine(key: key, value: newValues[i], lineEnding: lineEnding)
                }
            }
            if newValues.count > occurrences.count {
                let insertAt = (occurrences.last.map { $0 + 1 }) ?? lines.count
                let extras = newValues[occurrences.count...].map { settingLine(key: key, value: $0, lineEnding: lineEnding) }
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
                lines[last] = settingLine(key: key, value: newValues[0], lineEnding: lineEnding)
            }
        } else {
            lines.append(settingLine(key: key, value: newValues[0], lineEnding: lineEnding))
        }
        return renumber(lines)
    }

    private static func settingLine(key: String, value: String, lineEnding: String) -> ConfigLine {
        // Carry the file's line ending so editing a line in a CRLF file doesn't
        // silently rewrite just that line as LF (R23 byte fidelity).
        let terminator = lineEnding == "\r\n" ? "\r" : ""
        return ConfigLine(raw: "\(key) = \(value)\(terminator)", kind: .setting(key: key, value: value), lineNumber: 0)
    }

    private static func renumber(_ lines: [ConfigLine]) -> [ConfigLine] {
        lines.enumerated().map { ConfigLine(raw: $1.raw, kind: $1.kind, lineNumber: $0 + 1) }
    }

    // MARK: - Filesystem layer

    private static let locks = PathLocks()

    /// Apply an option change and persist it safely in one step.
    @discardableResult
    public func apply(optionName: String, values: [String], isRepeatable: Bool, in model: ConfigModel) throws -> WriteReceipt {
        try Self.rejectLineBreaks(key: optionName, values: values)
        let edited = editedFile(setting: optionName, to: values, isRepeatable: isRepeatable, in: model)
        return try commit(edited)
    }

    /// Refuse a key/value containing a newline — it would serialize into extra
    /// config directives (e.g. an injected `config-file`). Guards the public
    /// write entry points so a multi-line value can never reach disk (R8).
    private static func rejectLineBreaks(key: String, values: [String]) throws {
        func hasBreak(_ s: String) -> Bool { s.contains("\n") || s.contains("\r") }
        if hasBreak(key) { throw ConfigWriteError.invalidValue(key) }
        for value in values where hasBreak(value) {
            throw ConfigWriteError.invalidValue(value)
        }
    }

    /// Validate the proposed change against the live binary BEFORE writing, then
    /// commit only if it's valid (R15, R17). Throws `.validationFailed` without
    /// touching the real file when the result wouldn't validate.
    @discardableResult
    public func validateAndApply(
        optionName: String,
        values: [String],
        isRepeatable: Bool,
        in model: ConfigModel,
        cli: GhosttyCLI?,
        linter: ConfigLinter = ConfigLinter()
    ) async throws -> WriteReceipt {
        try Self.rejectLineBreaks(key: optionName, values: values)
        let edited = editedFile(setting: optionName, to: values, isRepeatable: isRepeatable, in: model)
        if let cli {
            let validation = try await validatePreview(edited: edited, model: model, cli: cli, linter: linter)
            guard validation.isValid else {
                throw ConfigWriteError.validationFailed(validation.messages)
            }
        }
        return try commit(edited)
    }

    /// Validate a whole batch (all ops folded into the primary) then commit it once, so a
    /// reset-all / reset-category is one backup, one validation, one reload, one undoable
    /// receipt (KTD5, G4). Same validate-before-write contract as the single-option path.
    @discardableResult
    public func validateAndApplyBatch(
        operations: [BatchOperation],
        in model: ConfigModel,
        cli: GhosttyCLI?,
        linter: ConfigLinter = ConfigLinter()
    ) async throws -> WriteReceipt {
        for op in operations { try Self.rejectLineBreaks(key: op.key, values: op.values) }
        let edited = editedFile(applying: operations, in: model)
        if let cli {
            let validation = try await validatePreview(edited: edited, model: model, cli: cli, linter: linter)
            guard validation.isValid else {
                throw ConfigWriteError.validationFailed(validation.messages)
            }
        }
        return try commit(edited)
    }

    /// Replace the ENTIRE primary config with `text` after validating it (G4 import =
    /// replace-with-backup). Validates the imported bytes in their real include context,
    /// then commits — so a bad paste is rejected over one backup and never reaches disk.
    /// The new file is stamped with the **current on-disk identity** (not the imported
    /// bytes' own), so the stale-overwrite guard compares against what's actually there
    /// now and doesn't misfire on the (intentionally different) imported content. When no
    /// file exists yet, the stamp is nil and the import creates it.
    @discardableResult
    public func validateAndImport(
        text: String,
        into model: ConfigModel,
        cli: GhosttyCLI?,
        linter: ConfigLinter = ConfigLinter(),
        fileManager: FileManager = .default
    ) async throws -> WriteReceipt {
        let primary = model.primary
        var newFile = ConfigFile.parse(text: text, path: primary.path, resolvedPath: primary.resolvedPath)
        newFile.identity = FileIdentity.capture(path: primary.resolvedPath, fileManager: fileManager)
        if let cli {
            let validation = try await validatePreview(edited: newFile, model: model, cli: cli, linter: linter)
            guard validation.isValid else {
                throw ConfigWriteError.validationFailed(validation.messages)
            }
        }
        return try commit(newFile, fileManager: fileManager)
    }

    /// Validate the proposed change against the **full merged config**, not the
    /// edited file in isolation. Reconstructs the whole tree (primary + every
    /// `config-file` include) in a throwaway temp dir — using the edited bytes for
    /// the edited file and rewriting `config-file` directives to point at the temp
    /// copies — then validates the temp primary. This makes an option set inside
    /// an include validate in its real context. The real files are untouched.
    private func validatePreview(edited: ConfigFile, model: ConfigModel, cli: GhosttyCLI, linter: ConfigLinter) async throws -> ValidationResult {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gcm-validate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Stable temp path per real file (index-based avoids basename collisions).
        var tempPaths: [String: URL] = [:]
        for (index, file) in model.allFiles.enumerated() {
            tempPaths[file.resolvedPath] = dir.appendingPathComponent("config-\(index)")
        }
        for file in model.allFiles {
            let source = file.resolvedPath == edited.resolvedPath ? edited : file
            let text = Self.rewriteIncludesForValidation(source, tempPaths: tempPaths)
            try Data(text.utf8).write(to: tempPaths[file.resolvedPath]!)
        }
        guard let primaryTemp = tempPaths[model.primary.resolvedPath] else {
            // Single-file fallback.
            let temp = dir.appendingPathComponent("config")
            try Data(edited.serialized().utf8).write(to: temp)
            return try await linter.validate(cli: cli, configFile: temp.path)
        }
        return try await linter.validate(cli: cli, configFile: primaryTemp.path)
    }

    /// Re-emit a file for validation, rewriting each `config-file` directive to
    /// point at the temp copy of its target so the include graph stays intact.
    private static func rewriteIncludesForValidation(_ file: ConfigFile, tempPaths: [String: URL]) -> String {
        let dir = (file.resolvedPath as NSString).deletingLastPathComponent
        let lines = file.lines.map { line -> String in
            guard case .setting(let key, let value) = line.kind, key == "config-file",
                  let resolved = ConfigReader.resolveIncludePath(value, relativeToDir: dir),
                  let tempURL = tempPaths[ConfigReader.canonicalPath(resolved)]
            else { return line.raw }
            return "config-file = \(tempURL.path)"
        }
        var out = lines.joined(separator: "\n")
        if file.hasTrailingNewline { out += "\n" }
        return out
    }

    /// Write `newFile` to its resolved real path with the full safety contract.
    @discardableResult
    public func commit(_ newFile: ConfigFile, fileManager: FileManager = .default) throws -> WriteReceipt {
        // Lock on the canonical real path so every spelling of the same inode
        // (symlink, ".."-laden, in-memory default) converges on one lock (H4).
        let realPath = ConfigReader.canonicalPath(newFile.resolvedPath)
        return try Self.locks.withLock(path: realPath) {
            try performCommit(newFile, realPath: realPath, fileManager: fileManager)
        }
    }

    private func performCommit(_ newFile: ConfigFile, realPath: String, fileManager: FileManager) throws -> WriteReceipt {
        // ONE read of the live file drives both the stale check and the backup,
        // so there is no window for an external write to slip between them (H1).
        let existing = fileManager.contents(atPath: realPath)
        let currentHash = existing.map { Self.sha256($0) }

        // Stale-overwrite guard (R22): the single read must match the read-time stamp.
        if let readStamp = newFile.identity {
            guard let currentHash, currentHash == readStamp.sha256 else {
                throw ConfigWriteError.staleOnDisk(path: realPath)
            }
        } else if existing != nil {
            // We thought this was a new file, but something created it since.
            throw ConfigWriteError.staleOnDisk(path: realPath)
        }

        let newData = Data(newFile.serialized().utf8)
        let dirURL = URL(fileURLWithPath: realPath).deletingLastPathComponent()
        // For a first write (no config yet) make sure the directory exists.
        try? fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)

        // Out-of-repo backup of the exact bytes we just read (R24). Abort if it fails.
        var backupURL: URL?
        var previousText: String?
        if let existing {
            previousText = String(decoding: existing, as: UTF8.self)
            do {
                backupURL = try makeBackup(of: existing, realPath: realPath, fileManager: fileManager)
            } catch {
                throw ConfigWriteError.backupFailed("\(error)")
            }
        }

        // Stage + atomic rename, preserving permissions/xattrs (R20, R21, R23).
        try stageAndRename(newData, to: realPath, dirURL: dirURL,
                           fallbackPermissions: newFile.identity?.permissions, fileManager: fileManager)

        return WriteReceipt(
            resolvedPath: realPath,
            backupURL: backupURL,
            newIdentity: FileIdentity.capture(path: realPath, fileManager: fileManager),
            previousText: previousText
        )
    }

    /// Restore the bytes captured in a receipt (last-write undo, R10). Backs up
    /// the CURRENT bytes first, so the undo is itself undoable and never blindly
    /// destroys an external edit made since the apply (H2); preserves attributes (H3).
    @discardableResult
    public func restore(from receipt: WriteReceipt, fileManager: FileManager = .default) throws -> Bool {
        guard let previous = receipt.previousText else { return false }
        let realPath = ConfigReader.canonicalPath(receipt.resolvedPath)
        return try Self.locks.withLock(path: realPath) {
            let dirURL = URL(fileURLWithPath: realPath).deletingLastPathComponent()
            if let current = fileManager.contents(atPath: realPath) {
                _ = try? makeBackup(of: current, realPath: realPath, fileManager: fileManager)
            }
            try stageAndRename(Data(previous.utf8), to: realPath, dirURL: dirURL,
                               fallbackPermissions: nil, fileManager: fileManager)
            return true
        }
    }

    /// Stage `data` to a same-dir temp with the live file's permissions/xattrs,
    /// full-sync it, atomically rename onto `realPath`, then full-sync the dir.
    /// Aborts with the temp removed (live file untouched) on any failure.
    private func stageAndRename(_ data: Data, to realPath: String, dirURL: URL, fallbackPermissions: UInt16?, fileManager: FileManager) throws {
        let livePermissions = Self.permissions(ofPath: realPath)
        let permissions = livePermissions ?? fallbackPermissions ?? 0o644
        let tempURL = dirURL.appendingPathComponent(".gcm-\(UUID().uuidString).tmp")
        do {
            // Non-atomic write: we own atomicity via our own rename below, and
            // this avoids Foundation leaving a differently-named temp on crash.
            try data.write(to: tempURL, options: [])
            try? fileManager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: tempURL.path)
            if fileManager.fileExists(atPath: realPath) {
                Self.copyExtendedAttributes(from: realPath, to: tempURL.path)
            }
            Self.fullSyncPath(tempURL.path) // F_FULLFSYNC: flush to stable media (R21)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw ConfigWriteError.stageFailed("\(error)")
        }
        guard rename(tempURL.path, realPath) == 0 else {
            let err = String(cString: strerror(errno))
            try? fileManager.removeItem(at: tempURL)
            throw ConfigWriteError.renameFailed(err)
        }
        Self.fullSyncPath(dirURL.path)
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
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
        let backups = entries.filter { $0.hasSuffix(".bak") }
        guard backups.count > retentionLimit else { return }
        // Order by the millisecond timestamp embedded in the filename — stable and
        // filesystem-independent (creationDate can be unavailable or reset).
        let sorted = backups.sorted { Self.backupTimestamp($0) < Self.backupTimestamp($1) }
        for name in sorted.prefix(sorted.count - retentionLimit) {
            try? fileManager.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private static func backupTimestamp(_ filename: String) -> Int {
        Int(filename.split(separator: "-").first ?? "") ?? 0
    }

    static func backupFolderName(for path: String) -> String {
        // Deterministic per real path across launches (R24 retention/recovery).
        // hashValue is per-process randomized and must never be persisted.
        let base = (path as NSString).lastPathComponent
        let digest = sha256(Data(path.utf8)).prefix(16)
        return "\(base)-\(digest)"
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - POSIX helpers

    private static func permissions(ofPath path: String) -> UInt16? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt16(info.st_mode & 0o7777)
    }

    /// Flush to STABLE media. Plain `fsync` on macOS only reaches the drive
    /// controller's cache; `F_FULLFSYNC` is required for real crash durability.
    private static func fullSyncPath(_ path: String) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) == -1 { fsync(fd) } // fall back if unsupported
        close(fd)
    }

    static func copyExtendedAttributes(from src: String, to dst: String) {
        let listSize = listxattr(src, nil, 0, 0)
        guard listSize > 0 else { return }
        var names = [CChar](repeating: 0, count: listSize)
        let got = listxattr(src, &names, listSize, 0)
        guard got > 0 else { return }
        // Names are NUL-terminated C strings of arbitrary bytes. Walk the raw
        // buffer by terminators rather than decoding to String and re-measuring,
        // which would desync the offset on a non-UTF-8 name.
        names.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var start = 0
            for i in 0..<got where names[i] == 0 {
                if i > start {
                    let namePtr = base.advanced(by: start)
                    let valueSize = getxattr(src, namePtr, nil, 0, 0, 0)
                    if valueSize > 0 {
                        var value = [UInt8](repeating: 0, count: valueSize)
                        if getxattr(src, namePtr, &value, valueSize, 0, 0) >= 0 {
                            _ = setxattr(dst, namePtr, value, valueSize, 0, 0)
                        }
                    }
                }
                start = i + 1
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
