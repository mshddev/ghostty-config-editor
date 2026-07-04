import XCTest
@testable import GhosttyConfigKit

/// The KTD5 additive batched-write path (G4): reset-all/category fold into one commit
/// (one backup / one validation / one reload / one undoable receipt), and whole-file
/// import replaces-with-backup after validating, stamped so the stale guard doesn't
/// misfire on the intentionally-different imported bytes.
final class BatchWriteTests: XCTestCase {

    // MARK: - Content layer (pure)

    func testBatchFoldsMultipleUnsetsIntoOnePrimaryFile() {
        let writer = ConfigWriter()
        let cfg = "font-size = 16\ncursor-style = bar\ncopy-on-select = true\n"
        let model = ConfigModel(primary: ConfigFile.parse(text: cfg, path: "/tmp/config", resolvedPath: "/tmp/config"))
        let ops: [ConfigWriter.BatchOperation] = [
            .unset("font-size", isRepeatable: false),
            .unset("cursor-style", isRepeatable: false),
        ]
        let edited = writer.editedFile(applying: ops, in: model)
        // Both unsets applied in one pass; the untouched line is byte-identical.
        XCTAssertEqual(edited.serialized(), "copy-on-select = true\n")
    }

    func testBatchLeavesThePrimaryUntouchedForKeysItDoesNotContain() {
        // Pins the invariant behind the app-side reset scoping (review #1): the batch only
        // rewrites the primary, so an unset op for a key that lives only in an include (not
        // the primary) is a no-op here — which is exactly why the app must NOT count or
        // promise to reset such options.
        let writer = ConfigWriter()
        let primary = "font-size = 16\n"
        let model = ConfigModel(primary: ConfigFile.parse(text: primary, path: "/tmp/config", resolvedPath: "/tmp/config"))
        let edited = writer.editedFile(applying: [.unset("cursor-style", isRepeatable: false)], in: model)
        XCTAssertEqual(edited.serialized(), primary, "unsetting a key absent from the primary must not change it")
    }

    func testBatchReconcilesRepeatableAndScalarOpsTogether() {
        let writer = ConfigWriter()
        let cfg = "keybind = ctrl+a=copy_to_clipboard\nkeybind = ctrl+b=paste_from_clipboard\nfont-size = 16\n"
        let model = ConfigModel(primary: ConfigFile.parse(text: cfg, path: "/tmp/config", resolvedPath: "/tmp/config"))
        let ops: [ConfigWriter.BatchOperation] = [
            .unset("keybind", isRepeatable: true),
            .unset("font-size", isRepeatable: false),
        ]
        let edited = writer.editedFile(applying: ops, in: model)
        // Every setting line is gone; the file's trailing newline is preserved (byte
        // fidelity, R23), so an emptied-out file is "\n", not "".
        XCTAssertEqual(edited.serialized(), "\n")
    }

    // MARK: - Filesystem: one commit, one undoable receipt

    func testBatchCommitsOnceYieldingOneReceiptThatUndoesTheWholeBatch() async throws {
        let dir = try tempDir()
        let original = "font-size = 16\ncursor-style = bar\ncopy-on-select = true\n"
        try write(original, dir, "config")
        let path = dir.appendingPathComponent("config").path
        let model = try ConfigReader().readModel(primaryPath: path)
        let writer = try makeWriter()

        let ops: [ConfigWriter.BatchOperation] = [
            .unset("font-size", isRepeatable: false),
            .unset("cursor-style", isRepeatable: false),
        ]
        // cli: nil skips the live-binary validation (this test is about the commit shape).
        let receipt = try await writer.validateAndApplyBatch(operations: ops, in: model, cli: nil)

        // A single write landed both unsets.
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "copy-on-select = true\n")
        // One receipt carries the WHOLE original, so a single undo reverts the whole batch
        // (not just the last op — the depth-1-undo footgun the batched path exists to avoid).
        XCTAssertEqual(receipt.previousText, original)
        _ = try writer.restore(from: receipt)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), original)
    }

    // MARK: - Whole-file import

    func testImportReplacesTheWholeFileAndIsUndoable() async throws {
        let dir = try tempDir()
        try write("font-size = 16\n", dir, "config")
        let path = dir.appendingPathComponent("config").path
        let model = try ConfigReader().readModel(primaryPath: path)
        let writer = try makeWriter()

        let receipt = try await writer.validateAndImport(
            text: "font-size = 20\ncursor-style = block\n", into: model, cli: nil)

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "font-size = 20\ncursor-style = block\n")
        XCTAssertEqual(receipt.previousText, "font-size = 16\n")
    }

    func testImportStampsCurrentIdentitySoStaleGuardDoesntMisfire() async throws {
        // The imported bytes differ from what's on disk by design. If the new file were
        // stamped with the IMPORTED bytes' hash, commit's stale check would compare disk
        // (old) vs stamp (new), mismatch, and wrongly throw staleOnDisk. Stamping with the
        // CURRENT on-disk identity makes the import go through.
        let dir = try tempDir()
        try write("font-size = 16\n", dir, "config")
        let path = dir.appendingPathComponent("config").path
        let model = try ConfigReader().readModel(primaryPath: path)
        let writer = try makeWriter()

        // Must not throw staleOnDisk even though content changes wholesale.
        _ = try await writer.validateAndImport(text: "font-size = 99\n", into: model, cli: nil)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "font-size = 99\n")
    }

    func testImportIntoMissingFileCreatesIt() async throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("config").path
        // No file yet — an empty model at the intended path (like AppModel.emptyModel).
        let model = ConfigModel(primary: ConfigFile.parse(text: "", path: path, resolvedPath: path))
        let writer = try makeWriter()

        _ = try await writer.validateAndImport(text: "font-size = 14\n", into: model, cli: nil)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "font-size = 14\n")
    }

    func testImportRejectsInvalidConfigBeforeWriting() async throws {
        guard let binary = BinaryLocator.locateForTests() else { throw XCTSkip("Ghostty not installed") }
        let dir = try tempDir()
        try write("font-size = 16\n", dir, "config")
        let path = dir.appendingPathComponent("config").path
        let model = try ConfigReader().readModel(primaryPath: path)
        let writer = try makeWriter()

        do {
            _ = try await writer.validateAndImport(
                text: "font-size = definitely-not-a-number\n", into: model,
                cli: GhosttyCLI(binaryPath: binary))
            XCTFail("expected the invalid import to be rejected")
        } catch ConfigWriteError.validationFailed {
            // good — rejected before writing
        }
        // The original file was never touched.
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "font-size = 16\n")
    }

    // MARK: - Helpers

    private func makeWriter() throws -> ConfigWriter {
        ConfigWriter(backupDirectory: try tempDir())
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gcm-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ contents: String, _ dir: URL, _ name: String) throws {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
