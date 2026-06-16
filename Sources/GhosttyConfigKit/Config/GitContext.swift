import Foundation

/// Detects whether a file lives inside a git working tree, so the UI can tell a
/// dotfiles user that an applied change landed in a git-tracked file (U7).
public enum GitContext {
    /// Walk up from the file's directory looking for a `.git` entry.
    public static func isInsideWorkingTree(path: String, fileManager: FileManager = .default) -> Bool {
        var directory = URL(fileURLWithPath: ConfigReader.canonicalPath(path)).deletingLastPathComponent()
        while true {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return true
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return false } // reached the filesystem root
            directory = parent
        }
    }
}
