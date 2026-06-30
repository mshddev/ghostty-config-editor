import XCTest
@testable import GhosttyConfigKit

final class KeybindMergeTests: XCTestCase {

    private let primary = "/cfg/config"
    private let include = "/cfg/keys.conf"

    private func loc(_ file: String, _ line: Int) -> SettingLocation {
        SettingLocation(file: file, line: line)
    }

    private func row(_ canonical: String, in rows: [MergedKeybind]) -> MergedKeybind? {
        rows.first { $0.canonicalTrigger == canonical }
    }

    // MARK: - Merge (RK1)

    func testMergeMarksDefaultsAddedAndOverrides() {
        let defaults = [DefaultKeybind(trigger: "super+t", action: "new_tab")]

        // A default left alone + a brand-new user binding.
        let added = KeybindMerge.userBindings(values: ["super+shift+t=new_tab"], sources: [loc(primary, 1)],
                                              knownActions: ["new_tab"])
        let merged = KeybindMerge.merge(defaults: defaults, user: added)
        XCTAssertEqual(row("super+t", in: merged)?.origin, .default)
        XCTAssertEqual(row("super+shift+t", in: merged)?.origin, .userAdded)

        // A user binding that re-binds the default's trigger overrides it.
        let override = KeybindMerge.userBindings(values: ["super+t=new_window"], sources: [loc(primary, 1)],
                                                 knownActions: ["new_window"])
        let merged2 = KeybindMerge.merge(defaults: defaults, user: override)
        let overrideRow = row("super+t", in: merged2)
        XCTAssertEqual(overrideRow?.origin, .userOverridesDefault(defaultAction: "new_tab"))
        XCTAssertEqual(overrideRow?.action, "new_window")
    }

    func testUnbindDisablesADefault() {
        let defaults = [DefaultKeybind(trigger: "super+shift+t", action: "new_tab")]

        // unbindingDefault on a pristine target file appends a `=unbind` line.
        let empty = TargetScopedBindings(userValues: [], sources: [], targetResolvedPath: primary)
        let values = empty.unbindingDefault(trigger: "super+shift+t")
        XCTAssertEqual(values, ["super+shift+t=unbind"])

        // …and re-reading that value marks the default disabled.
        let user = KeybindMerge.userBindings(values: values, sources: [loc(primary, 1)], knownActions: ["unbind"])
        let merged = KeybindMerge.merge(defaults: defaults, user: user)
        XCTAssertEqual(merged.first?.origin, .userDisablesDefault)
    }

    func testDuplicateCanonicalTriggerLastWinsInDisplay() {
        let user = KeybindMerge.userBindings(
            values: ["super+t=new_tab", "super+t=new_window"],
            sources: [loc(primary, 1), loc(primary, 2)],
            knownActions: ["new_tab", "new_window"])
        let merged = KeybindMerge.merge(defaults: [], user: user)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.action, "new_window")
    }

    // MARK: - Write-list edit operations (AE2, RK4)

    func testAddOrUpdateReplacesOnlyTheTargetBindingPreservingOthersVerbatim() {
        let values = ["super+a=new_tab", "super+b=new_window", "super+c=copy_to_clipboard:mixed", "super+d=close_surface"]
        let sources = [loc(primary, 1), loc(primary, 2), loc(primary, 3), loc(primary, 4)]
        let scoped = TargetScopedBindings(userValues: values, sources: sources, targetResolvedPath: primary,
                                          knownActions: ["new_tab", "new_window", "copy_to_clipboard", "close_surface"])

        let result = scoped.addingOrUpdating(trigger: "super+b", action: "goto_split:left")
        XCTAssertEqual(result, ["super+a=new_tab", "super+b=goto_split:left", "super+c=copy_to_clipboard:mixed", "super+d=close_surface"])
    }

    func testRemoveIsNoOpForMissingTriggerAndDropsExactlyTheMatch() {
        let values = ["super+a=new_tab", "super+b=new_window"]
        let sources = [loc(primary, 1), loc(primary, 2)]
        let scoped = TargetScopedBindings(userValues: values, sources: sources, targetResolvedPath: primary,
                                          knownActions: ["new_tab", "new_window"])

        XCTAssertEqual(scoped.removing(trigger: "super+z"), values, "missing trigger is a no-op")
        XCTAssertEqual(scoped.removing(trigger: "super+a"), ["super+b=new_window"])
    }

    func testAddOrUpdateCollapsesDuplicateTriggers() {
        let scoped = TargetScopedBindings(
            userValues: ["super+t=new_tab", "super+t=new_window"],
            sources: [loc(primary, 1), loc(primary, 2)],
            targetResolvedPath: primary,
            knownActions: ["new_tab", "new_window"])
        XCTAssertEqual(scoped.addingOrUpdating(trigger: "super+t", action: "close_surface"), ["super+t=close_surface"])
    }

    func testUnrelatedEditPreservesAPrefixedBindingVerbatim() {
        let scoped = TargetScopedBindings(
            userValues: ["global:ctrl+a=reload_config", "super+b=new_window"],
            sources: [loc(primary, 1), loc(primary, 2)],
            targetResolvedPath: primary,
            knownActions: ["reload_config", "new_window"])
        let result = scoped.addingOrUpdating(trigger: "super+b", action: "goto_split:left")
        XCTAssertEqual(result[0], "global:ctrl+a=reload_config", "the prefixed binding round-trips byte-for-byte (RK4/R11)")
    }

    // MARK: - Risk R-F: cross-file scoping prevents duplication

    func testWriteListIsScopedToTargetFileToPreventCrossFileDuplication() {
        // 2 bindings in the primary, 3 in an include.
        let values = ["super+a=new_tab", "super+b=new_window",
                      "super+c=copy_to_clipboard:mixed", "super+d=close_surface", "super+e=quit"]
        let sources = [loc(primary, 1), loc(primary, 2), loc(include, 1), loc(include, 2), loc(include, 3)]
        let scoped = TargetScopedBindings(userValues: values, sources: sources, targetResolvedPath: primary,
                                          knownActions: ["new_tab", "new_window", "copy_to_clipboard", "close_surface", "quit"])

        // Only the 2 primary bindings are in the write-list; the 3 include ones are excluded.
        XCTAssertEqual(scoped.rawValues, ["super+a=new_tab", "super+b=new_window"])

        // Editing one primary binding keeps the write-list at 2 entries…
        let newValues = scoped.addingOrUpdating(trigger: "super+a", action: "goto_split:left")
        XCTAssertEqual(newValues.count, 2)

        // …so the real position-wise reconcile against the primary's 2 keybind lines
        // changes only line 1 and never appends/duplicates an include binding.
        let primaryLines = [
            ConfigLine(raw: "keybind = super+a=new_tab", kind: .setting(key: "keybind", value: "super+a=new_tab"), lineNumber: 1),
            ConfigLine(raw: "keybind = super+b=new_window", kind: .setting(key: "keybind", value: "super+b=new_window"), lineNumber: 2),
        ]
        let mutated = ConfigWriter.mutate(primaryLines, key: "keybind", newValues: newValues, isRepeatable: true)
        XCTAssertEqual(mutated.compactMap(\.value), ["super+a=goto_split:left", "super+b=new_window"])
    }
}
