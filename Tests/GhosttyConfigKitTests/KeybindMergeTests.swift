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

    // MARK: - Conflict lookup (F4, CONTROLS-10/11)

    private func merged(_ trigger: String, _ action: String, _ origin: KeybindOrigin) -> MergedKeybind {
        MergedKeybind(trigger: trigger, action: action,
                      canonicalTrigger: KeybindTrigger.parse(trigger).canonical(),
                      origin: origin, source: nil)
    }

    func testConflictingActionFindsTheActionAlreadyBoundToTheChord() {
        let groups = KeybindMerge.group([
            merged("super+c", "copy_to_clipboard", .default),
            merged("", "new_split", .unbound),
        ])
        // Recording ⌘C for a different action collides with Copy — matched canonically.
        XCTAssertEqual(
            KeybindMerge.conflictingAction(forTrigger: "Super+C", excludingAction: "new_split", in: groups),
            "copy_to_clipboard"
        )
        // A free chord doesn't collide.
        XCTAssertNil(KeybindMerge.conflictingAction(forTrigger: "super+ctrl+k", excludingAction: "new_split", in: groups))
        // Recording the same chord for the SAME action is a second trigger, not a conflict.
        XCTAssertNil(KeybindMerge.conflictingAction(forTrigger: "super+c", excludingAction: "copy_to_clipboard", in: groups))
    }

    func testConflictingActionIgnoresDisabledDefaultsAndUnboundRows() {
        // ⌘C's default is turned off, so the chord is actually free.
        let disabled = KeybindMerge.group([merged("super+c", "copy_to_clipboard", .userDisablesDefault)])
        XCTAssertNil(KeybindMerge.conflictingAction(forTrigger: "super+c", excludingAction: "new_split", in: disabled))
        // An empty trigger never collides.
        XCTAssertNil(KeybindMerge.conflictingAction(forTrigger: "", excludingAction: "x", in: disabled))
    }

    // A conflict is found even when the colliding trigger is the action's *second* chord —
    // the scan is per chord, not just the first trigger of each action (U17).
    func testConflictingActionScansEverySecondaryChord() {
        // Copy carries two chords; recording ⌘C for another action must still collide.
        let groups = KeybindMerge.group([
            merged("copy", "copy_to_clipboard", .default),      // physical key (first chord)
            merged("super+c", "copy_to_clipboard", .default),   // ⌘C (second chord, same action)
            merged("", "new_split", .unbound),
        ])
        XCTAssertEqual(groups.first { $0.action == "copy_to_clipboard" }?.chords.count, 2)
        XCTAssertEqual(
            KeybindMerge.conflictingAction(forTrigger: "super+c", excludingAction: "new_split", in: groups),
            "copy_to_clipboard"
        )
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

    // MARK: - updating() — trigger change must move, not duplicate

    private func scoped(_ values: [String], _ known: Set<String>) -> TargetScopedBindings {
        TargetScopedBindings(
            userValues: values,
            sources: values.indices.map { loc(primary, $0 + 1) },
            targetResolvedPath: primary,
            knownActions: known)
    }

    func testUpdatingTriggerChangeMovesBindingInsteadOfDuplicating() {
        // The orphan bug: recording a new trigger over an existing binding must
        // replace it in place, not append a second line.
        let s = scoped(["super+t=new_window"], ["new_window"])
        let result = s.updating(originalTrigger: "super+t", trigger: "super+y", action: "new_window")
        XCTAssertEqual(result, ["super+y=new_window"])
    }

    func testUpdatingActionOnlyKeepsPositionAndPreservesPrefix() {
        // Editing the action of a prefixed binding (recorder untouched) keeps the
        // global: prefix and the line's position (RK4/R11).
        let s = scoped(["global:ctrl+a=reload_config", "super+b=new_window"], ["reload_config", "new_window", "new_tab"])
        let result = s.updating(originalTrigger: "global:ctrl+a", trigger: "global:ctrl+a", action: "new_tab")
        XCTAssertEqual(result, ["global:ctrl+a=new_tab", "super+b=new_window"])
    }

    func testUpdatingWithNilOriginalAppendsLikeAdd() {
        let s = scoped(["super+t=new_tab"], ["new_tab", "new_window"])
        XCTAssertEqual(s.updating(originalTrigger: nil, trigger: "super+w", action: "new_window"),
                       ["super+t=new_tab", "super+w=new_window"])
    }

    func testUpdatingTriggerChangeCollapsesACollisionWithAnExistingTrigger() {
        // Moving super+t onto super+w (which already exists) collapses to one line.
        let s = scoped(["super+t=new_tab", "super+w=new_window"], ["new_tab", "new_window"])
        let result = s.updating(originalTrigger: "super+t", trigger: "super+w", action: "new_tab")
        XCTAssertEqual(result, ["super+w=new_tab"])
    }

    // MARK: - movingDefault() — inline rebind of a default replaces, not appends

    func testMovingDefaultOnPristineFileWritesNewBindingAndUnbindsTheOld() {
        // Recording a new chord on an untouched default: the action moves to the new
        // keys and the old default is disabled, so it fires on the new keys only.
        let empty = TargetScopedBindings(userValues: [], sources: [], targetResolvedPath: primary)
        let values = empty.movingDefault(fromTrigger: "super+t", toTrigger: "super+shift+t", action: "new_tab")
        XCTAssertEqual(values, ["super+t=unbind", "super+shift+t=new_tab"])

        // Re-reading confirms the shape: the old default disabled, the new one added.
        let defaults = [DefaultKeybind(trigger: "super+t", action: "new_tab")]
        let user = KeybindMerge.userBindings(values: values, sources: [loc(primary, 1), loc(primary, 2)],
                                             knownActions: ["new_tab", "unbind"])
        let merged = KeybindMerge.merge(defaults: defaults, user: user)
        XCTAssertEqual(row("super+t", in: merged)?.origin, .userDisablesDefault)
        XCTAssertEqual(row("super+shift+t", in: merged)?.origin, .userAdded)
    }

    func testMovingDefaultToTheSameTriggerIsANoOp() {
        let scoped = scoped(["super+b=new_window"], ["new_window", "new_tab"])
        // Same canonical trigger (case/alias-insensitive) → nothing changes.
        XCTAssertEqual(scoped.movingDefault(fromTrigger: "super+t", toTrigger: "Super+T", action: "new_tab"),
                       ["super+b=new_window"])
    }

    func testMovingDefaultPreservesUnrelatedBindingsVerbatim() {
        let scoped = scoped(["global:ctrl+a=reload_config", "super+b=new_window"],
                            ["reload_config", "new_window", "new_tab"])
        let result = scoped.movingDefault(fromTrigger: "super+t", toTrigger: "super+y", action: "new_tab")
        XCTAssertEqual(result[0], "global:ctrl+a=reload_config", "unrelated prefixed binding round-trips verbatim")
        XCTAssertTrue(result.contains("super+t=unbind"))
        XCTAssertTrue(result.contains("super+y=new_tab"))
    }

    // MARK: - removingAction() — Restore default

    func testRemovingActionDropsRebindAndReenablesDisabledDefault() {
        // The goto_split case: the user disabled the ⌘[ default and rebound the action
        // to ⌃[. Restoring drops BOTH, reverting to Ghostty's ⌘[ default.
        // A sibling param variant (goto_split:next) must survive — restore is per full
        // action, not per action name.
        let s = scoped(["cmd+[=unbind", "ctrl+[=goto_split:previous", "ctrl+]=goto_split:next", "super+b=new_window"],
                       ["unbind", "goto_split", "new_window"])
        let result = s.removingAction("goto_split:previous",
                                      defaultTriggers: ["super+["],
                                      knownActions: ["unbind", "goto_split", "new_window"])
        XCTAssertEqual(result, ["ctrl+]=goto_split:next", "super+b=new_window"],
                       "the goto_split:previous rebind and its unbind go; goto_split:next and others stay")
    }

    func testRemovingActionLeavesUnrelatedUnbindsAndBindingsAlone() {
        // An unbind of a trigger that is NOT this action's default must be kept.
        let s = scoped(["cmd+q=unbind", "ctrl+x=new_tab"], ["unbind", "new_tab"])
        let result = s.removingAction("new_tab", defaultTriggers: ["super+t"],
                                      knownActions: ["unbind", "new_tab"])
        XCTAssertEqual(result, ["cmd+q=unbind"], "only the new_tab binding is removed; the unrelated unbind stays")
    }

    // MARK: - withUnboundActions() — list the whole action set

    func testWithUnboundActionsAppendsEmptyRowsForActionsWithNoBinding() {
        let defaults = [DefaultKeybind(trigger: "super+t", action: "new_tab")]
        let merged = KeybindMerge.merge(defaults: defaults, user: [])
        let actions = ["new_tab", "toggle_quick_terminal", "equalize_splits"].map { KeybindAction(name: $0) }

        let full = KeybindMerge.withUnboundActions(merged, allActions: actions)

        // The bound action keeps its single row; the two unbound ones get empty rows.
        XCTAssertEqual(full.filter { $0.action == "new_tab" }.count, 1)
        let quick = full.first { $0.action == "toggle_quick_terminal" }
        XCTAssertEqual(quick?.origin, .unbound)
        XCTAssertEqual(quick?.trigger, "")
        XCTAssertEqual(quick?.canonicalTrigger, "")
        // Unbound rows sort alphabetically and follow the bound rows.
        XCTAssertEqual(full.map(\.action), ["new_tab", "equalize_splits", "toggle_quick_terminal"])
        // Empty rows still get unique SwiftUI ids.
        XCTAssertEqual(Set(full.map(\.id)).count, full.count)
    }

    func testWithUnboundActionsExcludesNonBindableAndAlreadyBoundActions() {
        // A disabled default still counts as bound (its action shouldn't reappear as
        // "unbound"); unbind/text/csi/esc/cursor_key are never listed as empty rows.
        let defaults = [DefaultKeybind(trigger: "super+shift+t", action: "new_tab")]
        let user = KeybindMerge.userBindings(values: ["super+shift+t=unbind"], sources: [loc(primary, 1)],
                                             knownActions: ["unbind"])
        let merged = KeybindMerge.merge(defaults: defaults, user: user)
        let actions = ["new_tab", "unbind", "text", "csi", "esc", "cursor_key", "goto_window"].map { KeybindAction(name: $0) }

        let full = KeybindMerge.withUnboundActions(merged, allActions: actions)
        let unboundNames = full.filter { $0.origin == .unbound }.map(\.action)
        XCTAssertEqual(unboundNames, ["goto_window"], "only the real, param-free, unbound action is listed")
    }

    func testWithUnboundActionsDedupesRepeatedActionNames() {
        // A degenerate +list-actions that repeats a name must yield ONE unbound row, so two
        // `.unbound` MergedKeybinds don't share the `action:<name>` id and trip a SwiftUI
        // duplicate-id fault after grouping (matches merge()'s Risk R-B guard).
        let merged = KeybindMerge.merge(defaults: [], user: [])
        let actions = [KeybindAction(name: "toggle_quick_terminal"), KeybindAction(name: "toggle_quick_terminal")]
        let full = KeybindMerge.withUnboundActions(merged, allActions: actions)
        XCTAssertEqual(full.filter { $0.action == "toggle_quick_terminal" }.count, 1)
        XCTAssertEqual(Set(full.map(\.id)).count, full.count, "ids stay unique")
    }

    func testWithUnboundActionsIsNoOpWhenActionListIsEmpty() {
        let merged = KeybindMerge.merge(defaults: [DefaultKeybind(trigger: "super+t", action: "new_tab")], user: [])
        XCTAssertEqual(KeybindMerge.withUnboundActions(merged, allActions: []), merged)
    }

    func testMergeDeduplicatesDefaultsThatCanonicalizeIdentically() {
        // A degenerate defaults listing (Risk R-B) with two same-canonical triggers
        // collapses to one row so SwiftUI ids stay unique.
        let defaults = [DefaultKeybind(trigger: "super+t", action: "new_tab"),
                        DefaultKeybind(trigger: "Super+T", action: "new_window")]
        let merged = KeybindMerge.merge(defaults: defaults, user: [])
        XCTAssertEqual(merged.filter { $0.canonicalTrigger == "super+t" }.count, 1)
        XCTAssertEqual(merged.first?.action, "new_window", "last wins, matching Ghostty")
    }

    // MARK: - group() — one entry per action, chords folded in (U17, R8)

    private func defaultsFixture() throws -> [DefaultKeybind] {
        let actions = KeybindReference.parseActions(try Fixture.text("list-actions", "txt"))
        return KeybindReference.parseDefaults(try Fixture.text("list-keybinds-default", "txt"),
                                              knownActions: Set(actions.map(\.name)))
    }

    func testGroupFoldsDefaultsIntoOneEntryPerActionWithChordLists() throws {
        let merged = KeybindMerge.merge(defaults: try defaultsFixture(), user: [])
        let groups = KeybindMerge.group(merged)

        // 93 default binds collapse to 75 distinct actions; 18 of them carry two chords
        // (copy/paste/undo/goto_tab:1…8/…). (The plan estimated ~17; the 1.3.1 fixture is 18.)
        XCTAssertEqual(groups.count, 75)
        XCTAssertEqual(groups.filter { $0.chords.count == 2 }.count, 18)
        XCTAssertTrue(groups.allSatisfy { $0.chords.count == 1 || $0.chords.count == 2 })

        // Copy appears once, carrying both the physical Copy key and ⌘C.
        let copy = try XCTUnwrap(groups.first { $0.action == "copy_to_clipboard:mixed" })
        XCTAssertEqual(copy.chords.count, 2)
        XCTAssertEqual(Set(copy.chords.map(\.canonicalTrigger)),
                       [KeybindTrigger.parse("copy").canonical(), KeybindTrigger.parse("super+c").canonical()])
        XCTAssertTrue(copy.hasActiveShortcut)
        XCTAssertFalse(copy.isUnbound)
    }

    func testGroupKeepsADisabledDefaultAsAStruckChordInPlaceRatherThanDroppingTheRow() {
        // The LOCKED behavior flip (KB-2): an action whose only default is turned off keeps
        // its row with a `.userDisablesDefault` chord — it does NOT collapse to an empty
        // "No shortcut" row, and `withUnboundActions` must not re-add it as unbound.
        let defaults = [DefaultKeybind(trigger: "super+shift+t", action: "new_tab")]
        let user = KeybindMerge.userBindings(values: ["super+shift+t=unbind"], sources: [loc(primary, 1)],
                                             knownActions: ["unbind"])
        let merged = KeybindMerge.merge(defaults: defaults, user: user)
        let padded = KeybindMerge.withUnboundActions(merged, allActions: [KeybindAction(name: "new_tab")])
        let groups = KeybindMerge.group(padded)

        XCTAssertEqual(groups.count, 1)
        let group = groups[0]
        XCTAssertEqual(group.action, "new_tab")
        XCTAssertEqual(group.chords.map(\.origin), [.userDisablesDefault])
        XCTAssertFalse(group.isUnbound, "a turned-off default is a chord, not an unbound placeholder")
        XCTAssertFalse(group.hasActiveShortcut, "a turned-off default doesn't count as an active shortcut")
    }

    func testGroupPreservesPerChordOriginAndCollectsAddedChordsUnderOneAction() {
        // new_tab keeps its default (super+t) and gains a user-added chord (super+shift+t):
        // both land under a single new_tab group, in listed order, origins intact.
        let defaults = [DefaultKeybind(trigger: "super+t", action: "new_tab")]
        let user = KeybindMerge.userBindings(values: ["super+shift+t=new_tab"], sources: [loc(primary, 1)],
                                             knownActions: ["new_tab"])
        let merged = KeybindMerge.merge(defaults: defaults, user: user)
        let groups = KeybindMerge.group(merged)

        let group = try? XCTUnwrap(groups.first { $0.action == "new_tab" })
        XCTAssertEqual(group?.chords.count, 2)
        XCTAssertEqual(group?.chords.map(\.origin), [.default, .userAdded])
        XCTAssertEqual(group?.activeChords.count, 2)
    }

    func testGroupPlacesAnUnboundActionAsASingleEmptyPlaceholderChord() {
        let merged = KeybindMerge.merge(defaults: [], user: [])
        let padded = KeybindMerge.withUnboundActions(merged, allActions: [KeybindAction(name: "toggle_quick_terminal")])
        let groups = KeybindMerge.group(padded)

        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isUnbound)
        XCTAssertEqual(groups[0].chords.map(\.origin), [.unbound])
        XCTAssertTrue(groups[0].activeChords.isEmpty)
    }
}
