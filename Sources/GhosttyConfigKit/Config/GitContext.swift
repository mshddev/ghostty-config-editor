import Foundation

/// Detects whether a file lives inside a git working tree, so the UI can tell a
/// dotfiles user that an applied change landed in a git-tracked file (U7).
public enum GitContext {
    /// Walk up from the file's directory looking for a `.git` entry.
    ///
    /// Uses `NSString` path math rather than `URL.deletingLastPathComponent()`:
    /// the latter's fixed point at the filesystem root is Foundation-version
    /// dependent (some versions cycle `/` ↔ `/..` instead of converging on `/`),
    /// which turned this walk into an infinite loop on some hosts. NSString's
    /// `deletingLastPathComponent` converges on `/` predictably, and the explicit
    /// `parent == dir` guard is a belt-and-suspenders stop.
    public static func isInsideWorkingTree(path: String, fileManager: FileManager = .default) -> Bool {
        var dir = (ConfigReader.canonicalPath(path) as NSString).deletingLastPathComponent
        while !dir.isEmpty {
            if fileManager.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return true
            }
            if dir == "/" { return false } // reached the filesystem root
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { return false } // no upward progress — stop
            dir = parent
        }
        return false
    }
}
