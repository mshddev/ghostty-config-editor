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

    func testPaletteInteriorReconcileChangesOnlyThatLine() {
        // Same count, one interior value changes → only that line's raw differs.
        let cfg = "palette = 0=#000000\npalette = 1=#111111\npalette = 2=#222222\n"
        let edited = writer.editedFile(setting: "palette",
                                       to: ["0=#000000", "1=#ABCDEF", "2=#222222"],
                                       isRepeatable: true, in: model(cfg))
        XCTAssertEqual(edited.serialized(),
                       "palette = 0=#000000\npalette = 1=#ABCDEF\npalette = 2=#222222\n")
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

    // Review G2 #5: editing a CRLF file must keep CRLF on the edited/added line,
    // not silently rewrite it as LF.
    func testEditingCRLFFileKeepsCRLFOnEditedLine() {
        let cfg = "font-size = 16\r\nfont-family = Menlo\r\n"
        let edited = writer.editedFile(setting: "font-size", to: ["18"], isRepeatable: false, in: model(cfg))
        XCTAssertEqual(edited.serialized(), "font-size = 18\r\nfont-family = Menlo\r\n")
    }

    func testAppendedLineInCRLFFileUsesCRLF() {
        let cfg = "font-size = 16\r\n"
        let edited = writer.editedFile(setting: "cursor-style", to: ["bar"], isRepeatable: false, in: model(cfg))
        XCTAssertEqual(edited.serialized(), "font-size = 16\r\ncursor-style = bar\r\n")
    }

    func testLFFileStaysLFOnEdit() {
        let cfg = "font-size = 16\nfont-family = Menlo\n"
        let edited = writer.editedFile(setting: "font-size", to: ["18"], isRepeatable: false, in: model(cfg))
        XCTAssertEqual(edited.serialized(), "font-size = 18\nfont-family = Menlo\n")
    }

    // Review G2 #3: a value with a newline would inject extra directives — refuse it.
    func testApplyRejectsValueContainingNewline() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)

        XCTAssertThrowsError(
            try makeWriter().apply(optionName: "font-size",
                                   values: ["16\nconfig-file = /tmp/evil"],
                                   isRepeatable: false, in: m)
        ) { error in
            guard case .invalidValue = (error as? ConfigWriteError) else {
                return XCTFail("expected invalidValue, got \(error)")
            }
        }
        // No injected directive reached disk; the file is byte-intact.
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 16\n")
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

    func testRestoreBacksUpCurrentBytesBeforeReverting() throws {
        let dir = try tempDir()
        let backupDir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)
        let w = ConfigWriter(backupDirectory: backupDir)

        let receipt = try w.apply(optionName: "font-size", values: ["18"], isRepeatable: false, in: m)
        // An external edit lands AFTER the apply.
        try "font-size = 42\n".write(to: path, atomically: true, encoding: .utf8)

        try w.restore(from: receipt) // reverts to 16, but must not lose the 42 forever
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 16\n")

        // The pre-revert bytes (42) were backed up, so the undo is itself recoverable.
        let folder = backupDir.appendingPathComponent(ConfigWriter.backupFolderName(for: m.primary.resolvedPath))
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let contents = try backups.map { try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }
        XCTAssertTrue(contents.contains("font-size = 42\n"),
                      "restore must back up the bytes it is about to overwrite")
    }

    func testPermissionsPreservedThroughRestore() throws {
        let dir = try tempDir()
        let backupDir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: path.path)
        let m = try ConfigReader().readModel(primaryPath: path.path)
        let w = ConfigWriter(backupDirectory: backupDir)

        let receipt = try w.apply(optionName: "font-size", values: ["18"], isRepeatable: false, in: m)
        try w.restore(from: receipt)

        let perms = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.uint16Value, 0o600, "restore must preserve 0600 (R23)")
    }

    func testBackupFolderNameIsDeterministic() {
        // Stable across calls (and thus across launches) — never randomized.
        XCTAssertEqual(ConfigWriter.backupFolderName(for: "/a/b/config"),
                       ConfigWriter.backupFolderName(for: "/a/b/config"))
        XCTAssertNotEqual(ConfigWriter.backupFolderName(for: "/a/b/config"),
                          ConfigWriter.backupFolderName(for: "/a/c/config"))
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

        // U2: applyNotice is worded *additively* so it reads complementarily beneath
        // the scope-neutral auto-reload caption (KTD8). It must no longer begin with
        // the old corrective "This takes effect …" framing.
        let newSurfaceNotice = try XCTUnwrap(titlebar.applyNotice)
        XCTAssertFalse(newSurfaceNotice.hasPrefix("This takes effect"))
        let restartNotice = try XCTUnwrap(catalog.option(named: "background-opacity")?.applyNotice)
        XCTAssertFalse(restartNotice.hasPrefix("This takes effect"))
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
        guard let binary = BinaryLocator.locateForTests() else { throw XCTSkip("Ghostty not installed") }
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
        guard let binary = BinaryLocator.locateForTests() else { throw XCTSkip("Ghostty not installed") }
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)

        try await makeWriter().validateAndApply(
            optionName: "font-size", values: ["18"],
            isRepeatable: false, in: m, cli: GhosttyCLI(binaryPath: binary))

        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 18\n")
    }

    func testValidateAndApplyToIncludeOptionRoundTrips() async throws {
        guard let binary = BinaryLocator.locateForTests() else { throw XCTSkip("Ghostty not installed") }
        let dir = try tempDir()
        try write("config-file = extra.conf\nfont-size = 16\n", dir, "config")
        try write("cursor-style = bar\n", dir, "extra.conf")
        let m = try ConfigReader().readModel(primaryPath: dir.appendingPathComponent("config").path)

        // cursor-style lives in the include; a valid change must apply there.
        try await makeWriter().validateAndApply(
            optionName: "cursor-style", values: ["underline"],
            isRepeatable: false, in: m, cli: GhosttyCLI(binaryPath: binary))

        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("extra.conf"), encoding: .utf8),
                       "cursor-style = underline\n")
    }

    func testValidateAndApplyRejectsInvalidIncludeEditAgainstMergedTree() async throws {
        guard let binary = BinaryLocator.locateForTests() else { throw XCTSkip("Ghostty not installed") }
        let dir = try tempDir()
        try write("config-file = extra.conf\nfont-size = 16\n", dir, "config")
        try write("cursor-style = bar\n", dir, "extra.conf")
        let m = try ConfigReader().readModel(primaryPath: dir.appendingPathComponent("config").path)

        do {
            _ = try await makeWriter().validateAndApply(
                optionName: "cursor-style", values: ["not-a-cursor-style"],
                isRepeatable: false, in: m, cli: GhosttyCLI(binaryPath: binary))
            XCTFail("invalid include edit should be rejected via merged-tree validation")
        } catch ConfigWriteError.validationFailed {
            // expected
        }
        // The include is untouched.
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("extra.conf"), encoding: .utf8),
                       "cursor-style = bar\n")
    }

    // MARK: - Empty-config guard (A · would-be-empty write)
    //
    // Ghostty's `+validate-config` rejects a *zero-byte* config with exit 1 and no
    // diagnostic, which the presenter can only render as the opaque "The change didn't
    // validate." The writer intercepts a would-be-empty result up front — strictly
    // `.isEmpty`, since Ghostty accepts whitespace/comment-only files — so the clear
    // message wins and no zero-byte file ever reaches disk. These are hermetic: the guard
    // fires before validation, so no live binary is needed.

    func testImportingEmptyTextIsRejected() async throws {
        let dir = try tempDir()
        let m = model("font-size = 16\n", path: dir.appendingPathComponent("config").path)
        do {
            _ = try await makeWriter().validateAndImport(text: "", into: m, cli: nil)
            XCTFail("importing an empty config should be rejected")
        } catch {
            XCTAssertEqual(error as? ConfigWriteError, .emptyConfig)
        }
    }

    func testUnsettingTheLastOptionOnANoTrailingNewlineFileIsRejected() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try "font-size = 16".write(to: path, atomically: true, encoding: .utf8) // no trailing newline
        let m = try ConfigReader().readModel(primaryPath: path.path)

        XCTAssertThrowsError(try makeWriter().apply(optionName: "font-size", values: [], isRepeatable: false, in: m)) {
            XCTAssertEqual($0 as? ConfigWriteError, .emptyConfig)
        }
        // The guard fires before any write — the live file is byte-intact.
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 16")
    }

    func testBatchThatEmptiesTheFileIsRejected() async throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try "font-size = 16".write(to: path, atomically: true, encoding: .utf8) // no trailing newline
        let m = try ConfigReader().readModel(primaryPath: path.path)

        do {
            _ = try await makeWriter().validateAndApplyBatch(
                operations: [.unset("font-size", isRepeatable: false)], in: m, cli: nil)
            XCTFail("a batch that empties the file should be rejected")
        } catch {
            XCTAssertEqual(error as? ConfigWriteError, .emptyConfig)
        }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "font-size = 16")
    }

    func testCommitOfAZeroByteFileIsRejectedAsBackstop() throws {
        // Direct-`commit()` callers hit the performCommit backstop even without the
        // per-entry-point guard, so no path can put a zero-byte file on disk.
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config").path
        let empty = ConfigFile.parse(text: "", path: path, resolvedPath: path)
        XCTAssertThrowsError(try makeWriter().commit(empty)) {
            XCTAssertEqual($0 as? ConfigWriteError, .emptyConfig)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "no zero-byte file should be created")
    }

    func testCommentOnlyResultIsNotRejected() throws {
        // Unsetting the only setting leaves a comment-only file — valid to Ghostty, so
        // the strictly-zero-byte guard must let it persist.
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("# just a comment\nfont-size = 16\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)

        try makeWriter().apply(optionName: "font-size", values: [], isRepeatable: false, in: m)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "# just a comment\n")
    }

    func testUnsettingLastOptionOnTrailingNewlineFileLeavesABlankLine() throws {
        // Removing the last line of a newline-terminated file leaves "\n" (not zero bytes),
        // which Ghostty accepts — so the guard must let it through unchanged.
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config")
        try write("font-size = 16\n", dir, "config")
        let m = try ConfigReader().readModel(primaryPath: path.path)

        try makeWriter().apply(optionName: "font-size", values: [], isRepeatable: false, in: m)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "\n")
    }

    func testEmptyConfigPresentsAClearMessage() {
        let presentation = EditErrorPresentation.present(ConfigWriteError.emptyConfig)
        XCTAssertEqual(presentation.message,
                       "A config file can't be empty. Reset options to defaults instead of clearing the file.")
        XCTAssertNil(presentation.detail)
        XCTAssertFalse(presentation.offersReload)
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
