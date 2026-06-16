import XCTest
@testable import GhosttyConfigKit

/// Characterization-first (per the U6 execution note): these assert the exact
/// byte-preservation and crash-safety behavior the writer must never regress.
final class ConfigWriterTests: XCTestCase {

    private let writer = ConfigWriter(backupDirectory: ConfigWriter.defaultBackupDirectory)

    private func model(_ text: String, path: String = "/tmp/config") -> ConfigModel {
        ConfigModel(primary: ConfigFile.parse(text: text, path: path, resolvedPath: path))
    }

    // MARK: - Content layer: byte preservation (R8, R11)

    func testAE2_EditingOneKeybindLeavesOthersByteIdentical() {
        let cfg = "keybind = a=b\nkeybind = c=d\nkeybind = e=f\nkeybind = g=h\n"
        let edited = writer.editedFile(setting: "keybind",
                                       to: ["a=b", "c=CHANGED", "e=f", "g=h"],
                                       isRepeatable: true, in: model(cfg))
        XCTAssertEqual(edited.serialized(),
                       "keybind = a=b\nkeybind = c=CHANGED\nkeybind = e=f\nkeybind = g=h\n")
    }

    func testAE3_CommentAndUnknownLineSurviveUnrelatedEdit() {
        let cfg = "# my splits\nfont-size = 16\n@@@ a line we don't recognize\nfont-family = Menlo\n"
        let edited = writer.editedFile(setting: "font-size", to: ["17"], isRepeatable: false, in: model(cfg))
        XCTAssertEqual(edited.serialized(),
                       "# my splits\nfont-size = 17\n@@@ a line we don't recognize\nfont-family = Menlo\n")
    }

    func testPaletteRemoveUpdatesOnlyThatKeysLines() {
        let cfg = "palette = 0=#000000\npalette = 1=#111111\npalette = 2=#222222\nfont-size = 16\n"
        let edited = writer.editedFile(setting: "palette",
                                       to: ["0=#000000", "2=#222222"],
                                       isRepeatable: true, in: model(cfg))
        XCTAssertEqual(edited.serialized(),
                       "palette = 0=#000000\npalette = 2=#222222\nfont-size = 16\n")
    }

    func testPaletteAddAppendsAfterExistingBlock() {
        let cfg = "palette = 0=#000000\nfont-size = 16\n"
        let edited = writer.editedFile(setting: "palette",
                                       to: ["0=#000000", "1=#111111"],
                                       isRepeatable: true, in: model(cfg))
        XCTAssertEqual(edited.serialized(),
                       "palette = 0=#000000\npalette = 1=#111111\nfont-size = 16\n")
    }

    func testSetScalarAppendsWhenAbsent() {
        let edited = writer.editedFile(setting: "cursor-style", to: ["bar"], isRepeatable: false,
                                       in: model("font-size = 16\n"))
        XCTAssertEqual(edited.serialized(), "font-size = 16\ncursor-style = bar\n")
    }

    func testUnsetRemovesTheLine() {
        let edited = writer.editedFile(setting: "font-size", to: [], isRepeatable: false,
                                       in: model("font-size = 16\nfont-family = Menlo\n"))
        XCTAssertEqual(edited.serialized(), "font-family = Menlo\n")
    }

    func testFullFileDiffShowsExactlyTheIntendedHunk() {
        let cfg = "# header\nfont-family = Menlo\nfont-size = 16\nwindow-save-state = always\n"
        let edited = writer.editedFile(setting: "font-size", to: ["18"], isRepeatable: false, in: model(cfg))
        let before = cfg.components(separatedBy: "\n")
        let after = edited.serialized().components(separatedBy: "\n")
        let changed = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.element.1, "font-size = 18")
    }

    func testNonASCIIValuesRoundTripExceptEditedLine() {
        let cfg = "# café ☕\nfont-family = \"Menlö\"\nfont-size = 16\n"
        let edited = writer.editedFile(setting: "font-size", to: ["17"], isRepeatable: false, in: model(cfg))
        XCTAssertEqual(edited.serialized(), "# café ☕\nfont-family = \"Menlö\"\nfont-size = 17\n")
    }

    // MARK: - Write-target selection (R8)

    func testWriteTargetPicksIncludeWhenOptionLivesThere() throws {
        let dir = try tempDir()
        try write("config-file = extra.conf\n", dir, "config")
        try write("cursor-style = bar\n", dir, "extra.conf")
        let m = try ConfigReader().readModel(primaryPath: dir.appendingPathComponent("config").path)

        let target = writer.targetFile(forOption: "cursor-style", in: m)
        XCTAssertTrue(target.resolvedPath.hasSuffix("extra.conf"))

        let primaryTarget = writer.targetFile(forOption: "font-size", in: m)
        XCTAssertEqual(primaryTarget.resolvedPath, m.primary.resolvedPath)
    }

    // MARK: - Filesystem: durability + fidelity (R20–R24)

    func testEditPersistsAndOnlyIntendedHunkChangesOnDisk() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("# header\nfont-size = 16\nfont-family = Menlo\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)

        try makeWriter().apply(optionName: "font-size", values: ["18"], isRepeatable: false, in: m)

        let onDisk = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(onDisk, "# header\nfont-size = 18\nfont-family = Menlo\n")
    }

    func testNoTrailingNewlineStaysAbsent() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try "font-size = 16".write(to: path, atomically: true, encoding: .utf8) // no trailing newline
        let m = try ConfigReader().readModel(primaryPath: path.path)

        try makeWriter().apply(optionName: "font-size", values: ["17"], isRepeatable: false, in: m)

        let onDisk = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(onDisk, "font-size = 17")
        XCTAssertFalse(onDisk.hasSuffix("\n"))
    }

    func testPermissionsArePreserved() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: path.path)
        let m = try ConfigReader().readModel(primaryPath: path.path)

        try makeWriter().apply(optionName: "font-size", values: ["17"], isRepeatable: false, in: m)

        let perms = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.uint16Value, 0o600)
    }

    func testSymlinkIsPreservedAndStillPointsAtRealFile() throws {
        let dir = try tempDir()
        let realPath = dir.appendingPathComponent("real-config").path
        let linkPath = dir.appendingPathComponent("config").path
        try write("font-size = 16\n", dir, "real-config")
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: realPath)

        let m = try ConfigReader().readModel(primaryPath: linkPath)
        try makeWriter().apply(optionName: "font-size", values: ["18"], isRepeatable: false, in: m)

        // The symlink is intact (NOT replaced by a regular file) and still points
        // at the real file, which now holds the new content.
        let attrs = try FileManager.default.attributesOfItem(atPath: linkPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkPath), realPath)
        XCTAssertEqual(try String(contentsOfFile: realPath, encoding: .utf8), "font-size = 18\n")
    }

    func testStaleOnDiskChangeIsRefused() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)

        // Someone else edits the file after we read it.
        try "font-size = 99\n".write(to: path, atomically: true, encoding: .utf8)

        let edited = writer.editedFile(setting: "font-size", to: ["17"], isRepeatable: false, in: m)
        XCTAssertThrowsError(try makeWriter().commit(edited)) { error in
            XCTAssertEqual(error as? ConfigWriteError, .staleOnDisk(path: m.primary.resolvedPath))
        }
        // The external change is left intact.
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 99\n")
    }

    func testStagingFailureAbortsWithOriginalUntouched() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)
        let edited = writer.editedFile(setting: "font-size", to: ["17"], isRepeatable: false, in: m)

        // Make the config directory read-only so the same-dir temp write fails
        // (a stand-in for disk-full / I/O failure). Backup still succeeds.
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: dir.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: dir.path)
        }

        XCTAssertThrowsError(try makeWriter().commit(edited))
        // Restore write access to read the original back.
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: dir.path)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 16\n",
                       "the live file must be byte-intact after an aborted write")
    }

    func testBackupFailureAbortsWithOriginalUntouched() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)
        let edited = writer.editedFile(setting: "font-size", to: ["17"], isRepeatable: false, in: m)

        // Point the backup dir at a *file*, so createDirectory fails.
        let blocker = dir.appendingPathComponent("not-a-dir")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let badWriter = ConfigWriter(backupDirectory: blocker)

        XCTAssertThrowsError(try badWriter.commit(edited)) { error in
            guard case .backupFailed = (error as? ConfigWriteError) else {
                return XCTFail("expected backupFailed, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 16\n")
    }

    func testBackupsLandInBackupDirectoryNotConfigDir() throws {
        let dir = try tempDir()
        let backupDir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)

        let receipt = try ConfigWriter(backupDirectory: backupDir)
            .apply(optionName: "font-size", values: ["17"], isRepeatable: false, in: m)

        let backupURL = try XCTUnwrap(receipt.backupURL)
        XCTAssertTrue(backupURL.path.hasPrefix(backupDir.path), "backup must live under the backup dir")
        XCTAssertFalse(backupURL.path.hasPrefix(dir.path), "backup must NOT pollute the config dir")
        // No stray .bak files in the config dir.
        let configDirContents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(configDirContents.contains { $0.hasSuffix(".bak") })
        // The backed-up bytes are the pre-edit content.
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "font-size = 16\n")
    }

    func testRestoreUndoesTheLastWrite() throws {
        let dir = try tempDir()
        let backupDir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)
        let w = ConfigWriter(backupDirectory: backupDir)

        let receipt = try w.apply(optionName: "font-size", values: ["18"], isRepeatable: false, in: m)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 18\n")

        XCTAssertTrue(try w.restore(from: receipt))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 16\n")
    }

    func testCrashRecoverySweepsStaleTempsButLeavesConfig() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        // Simulate a temp left behind by a crashed write.
        try "partial".write(to: dir.appendingPathComponent(".gcm-orphan.tmp"), atomically: true, encoding: .utf8)

        writer.sweepStaleTempFiles(inDirectoryOf: path.path)

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(contents.contains { $0.hasPrefix(".gcm-") }, "orphan temp should be swept")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 16\n", "config untouched")
    }

    // MARK: - U7 apply flow

    func testChangeScopeDetectedFromDocs() throws {
        let catalog = CatalogParser.parse(try Fixture.text("show-config-default-docs", "txt"))
        // "only applies to new windows" → newSurface (AE5).
        let titlebar = try XCTUnwrap(catalog.option(named: "macos-titlebar-style"))
        XCTAssertEqual(titlebar.changeScope, .newSurface)
        XCTAssertNotNil(titlebar.applyNotice)
        // "requires restarting Ghostty completely" → restart.
        XCTAssertEqual(catalog.option(named: "background-opacity")?.changeScope, .restart)
    }

    func testGitContextDetectsWorkingTree() throws {
        let dir = try tempDir()
        try write("font-size = 16\n", dir, "config")
        XCTAssertFalse(GitContext.isInsideWorkingTree(path: dir.appendingPathComponent("config").path))

        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertTrue(GitContext.isInsideWorkingTree(path: dir.appendingPathComponent("config").path),
                      "a file under a dir containing .git is in a working tree")
    }

    func testValidateAndApplyRejectsInvalidWithoutWriting() async throws {
        guard let binary = BinaryLocator.locateOnSystem() else { throw XCTSkip("Ghostty not installed") }
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)

        do {
            _ = try await makeWriter().validateAndApply(
                optionName: "font-size", values: ["definitely-not-a-number"],
                isRepeatable: false, in: m, cli: GhosttyCLI(binaryPath: binary))
            XCTFail("expected validation to reject the bad value")
        } catch ConfigWriteError.validationFailed(let messages) {
            XCTAssertTrue(messages.contains { $0.key == "font-size" })
        }
        // The real file was never touched.
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 16\n")
    }

    func testValidateAndApplyRoundTripsValidChange() async throws {
        guard let binary = BinaryLocator.locateOnSystem() else { throw XCTSkip("Ghostty not installed") }
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)

        try await makeWriter().validateAndApply(
            optionName: "font-size", values: ["18"],
            isRepeatable: false, in: m, cli: GhosttyCLI(binaryPath: binary))

        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 18\n")
    }

    // MARK: - Helpers

    /// A writer whose backups go to a fresh temp dir outside any config dir.
    private func makeWriter() throws -> ConfigWriter {
        ConfigWriter(backupDirectory: try tempDir())
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gcm-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func write(_ contents: String, _ dir: URL, _ name: String) throws {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
