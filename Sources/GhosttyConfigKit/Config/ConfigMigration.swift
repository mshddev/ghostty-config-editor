import Foundation

/// The single legacy-to-preferred filename migration: renaming an extension-less
/// `config` to `config.ghostty`.
///
/// Why a rename matters at all: Ghostty ≥ 1.3 doesn't just prefer the `.ghostty`
/// name — its macOS Open Config action (⌘,) resolves which editor to launch via
/// the LaunchServices default app *for the file's extension*. An extension-less
/// `config` therefore always opens in the system text editor, while
/// `config.ghostty` can route to this app. The rename is what makes that
/// integration reachable for configs created before Ghostty 1.3.
public enum ConfigMigration {

    public enum MigrationError: Error, Equatable, Sendable {
        /// The offer was re-validated at execution time and no longer holds
        /// (file gone, already renamed, or a preferred-name sibling appeared).
        case nothingToRename
    }

    /// The rename this migration would perform for the given primary config, or
    /// nil when there is nothing to offer: the primary already carries the
    /// preferred name, doesn't exist yet, or a preferred-name sibling already
    /// exists. The sibling guard is safety-critical twice over — renaming onto it
    /// would destroy it, and when both names exist the reader already treats the
    /// sibling as primary, so the legacy file wouldn't be the active config anyway.
    public static func renameOffer(
        forPrimaryAt primaryPath: String,
        fileManager: FileManager = .default
    ) -> (from: String, to: String)? {
        let from = URL(fileURLWithPath: primaryPath)
        guard from.lastPathComponent == ConfigReader.legacyFilename,
              fileManager.fileExists(atPath: from.path) else { return nil }
        let to = from.deletingLastPathComponent()
            .appendingPathComponent(ConfigReader.preferredFilename)
        guard !fileManager.fileExists(atPath: to.path) else { return nil }
        return (from: from.path, to: to.path)
    }

    /// Rename the legacy primary to the preferred name, returning the new path.
    /// Re-validates the offer at execution time (never trusting a stale UI state),
    /// so a file that vanished or a sibling that appeared since the button was
    /// drawn fails cleanly instead of clobbering anything.
    public static func renameLegacyPrimary(
        at primaryPath: String,
        fileManager: FileManager = .default
    ) throws -> String {
        guard let offer = renameOffer(forPrimaryAt: primaryPath, fileManager: fileManager) else {
            throw MigrationError.nothingToRename
        }
        try fileManager.moveItem(atPath: offer.from, toPath: offer.to)
        return offer.to
    }
}
