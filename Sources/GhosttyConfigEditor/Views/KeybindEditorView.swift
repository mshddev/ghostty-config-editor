import SwiftUI
import AppKit
import GhosttyConfigKit

/// The Keybindings editor surface: Ghostty's whole action set as **one row per action**
/// (defaults + the user's bindings + every still-unbound action), each action carrying
/// its chords as capsules — click a capsule and press the new keys to rebind, exactly
/// like a system shortcuts pane (RK1–RK4, R16, AE4, U17). A trailing "+" capsule adds a
/// second shortcut; advanced grammar and per-chord edits live in each row's `⋯` menu and
/// context menus. Edits route through `AppModel` to the safe write path, and the existing
/// footgun lint is shown inline.
struct KeybindEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var didLoad = false
    @State private var filter = ""

    var body: some View {
        let all = model.keybindGroups
        let groups = filtered(all)
        // Which base actions carry >1 distinct param, so their param folds into the title
        // (goto_tab:1…8) rather than reading as a lone caption (copy_to_clipboard:mixed).
        // Computed over the *full* set so filtering never changes a row's title (KB-4).
        let foldParams = ActionLabelCatalog.multiParamActions(in: all.map(\.action))
        return VStack(spacing: 0) {
            SurfaceHeader(
                title: OptionCategorizer.keybindingsCategory,
                subtitle: didLoad ? countSummary(all) : nil,
                searchText: $filter,
                searchPrompt: "Filter by action or shortcut"
            )
            keybindHint
            Divider()
            if !didLoad {
                ProgressView("Loading keybindings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                bindingList(groups, foldParams: foldParams)
            }
            lintBar
            SurfaceFeedbackBar(applyState: model.applyState)
        }
        .task {
            await model.loadKeybindReferenceIfNeeded()
            didLoad = true
        }
    }

    /// The header count, matching the visible rows: every listed action, and how many
    /// carry an active shortcut (KB-7/CM-12 — the count is over *actions* now, not
    /// triggers, so it can't undercount against the rows on screen). Disabled defaults
    /// and unbound actions aren't "with a shortcut".
    private func countSummary(_ all: [KeybindActionGroup]) -> String {
        let total = all.count
        let withShortcut = all.filter(\.hasActiveShortcut).count
        return "\(total) actions, \(withShortcut) with a shortcut"
    }

    /// Filter by friendly title, raw action name, or any chord's shortcut text
    /// (case-insensitive), so ~140 rows stay navigable. Matches the raw id too (R8: a
    /// power user who knows `copy_to_clipboard` still finds it), and searches *across*
    /// an action's chords so ⌘C finds Copy even though the physical key is its first chord.
    private func filtered(_ groups: [KeybindActionGroup]) -> [KeybindActionGroup] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.filter { group in
            if group.action.lowercased().contains(q) { return true }
            if ActionLabelCatalog.bundled.displayTitle(for: group.action).lowercased().contains(q) { return true }
            return group.chords.contains { chord in
                !chord.trigger.isEmpty
                    && (chord.trigger.lowercased().contains(q)
                        || KeybindTrigger.displaySymbol(for: chord.trigger).lowercased().contains(q))
            }
        }
    }

    /// The inline instruction, kept under the shared header (it's specific to this
    /// surface's inline-recorder interaction, so it doesn't belong in SurfaceHeader).
    private var keybindHint: some View {
        Text("Click a shortcut and press the new keys to rebind, or “+” to add another. Actions with no shortcut are listed too.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    private func bindingList(_ groups: [KeybindActionGroup], foldParams: Set<String>) -> some View {
        // Computed once per render, not per row.
        let restorable = model.restorableActions
        return List(groups) { group in
            KeybindRow(group: group,
                       foldParams: foldParams,
                       canRestoreDefault: restorable.contains(group.action))
        }
    }

    private var keybindFindings: [LintFinding] {
        (model.lintReport?.findings ?? []).filter { $0.rule.hasPrefix("keybind") }
    }

    @ViewBuilder
    private var lintBar: some View {
        if !keybindFindings.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(keybindFindings) { finding in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: Self.icon(for: finding.severity))
                            .foregroundStyle(Self.color(for: finding.severity))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(finding.title).font(.caption.bold())
                            Text(finding.message).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.4))
        }
    }

    static func icon(for severity: LintFinding.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    static func color(for severity: LintFinding.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}

/// One row: the action (the config item) on the left with an origin badge, and its
/// chords on the right as capsules — each an **inline key recorder** (click and press
/// the new chord to rebind) with a remove affordance, plus a trailing "+" to add another
/// shortcut. A default the user turned off shows struck-through in place with a one-click
/// re-enable (KB-2). Out-of-target chords render read-only (Risk R-F); an action with no
/// shortcut renders a single empty, bindable recorder.
private struct KeybindRow: View {
    @Environment(AppModel.self) private var model
    let group: KeybindActionGroup
    /// Base actions whose `:param` folds into the title (KB-4) — passed down so the whole
    /// list agrees, and the decision doesn't change under search.
    let foldParams: Set<String>
    /// True when this action has a Ghostty default the user has changed, so a
    /// "Restore default" item is offered (re-enables the default, drops the rebind).
    let canRestoreDefault: Bool

    /// A soft, transient warning from the recorder (e.g. "add a modifier").
    @State private var warning: String?
    /// A pending conflict-at-capture prompt (F4): the chord the user just recorded, the
    /// action it already collides with, and which edit to commit on Replace.
    @State private var pendingConflict: PendingConflict?
    /// "Add another shortcut" popover (a second trigger for this row's action).
    @State private var showingAddAnother = false
    @State private var addAnotherDraft = ""
    /// "Edit as text" popover, scoped to a specific chord (advanced trigger grammar).
    @State private var textEditChord: MergedKeybind?
    @State private var textDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                actionColumn
                Spacer(minLength: 12)
                chordArea
                    .popover(isPresented: $showingAddAnother, arrowEdge: .bottom) { addAnotherEditor }
                    .popover(item: $textEditChord, arrowEdge: .bottom) { chord in textEditor(chord) }
            }
            // H2/A11Y-3: the row is NOT `.combine`d — that flattened the key recorders
            // (NSViews with their own role/label/value) and the ⋯ menu out of VoiceOver's
            // reach. Only the action column collapses to one element (below); the recorders
            // and menu stay first-class, individually focusable and operable.
            if let pendingConflict {
                conflictPrompt(pendingConflict)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, RowMetrics.rowVerticalPadding)
    }

    // MARK: Action (the config item)

    /// The friendly action title (A2), folding a humanized `:param` into the title only
    /// for multi-param base actions (KB-4). The raw id (params included) stays reachable
    /// as the title's tooltip and via search.
    private var friendlyTitle: String {
        ActionLabelCatalog.bundled.displayTitle(for: group.action, foldingParamsFor: foldParams)
    }

    /// A one-line description for the action, or empty when none is curated. Keyed by the
    /// param-less action name (`goto_split:previous` → `goto_split`), so param variants
    /// share the base action's summary.
    private var actionSummary: String {
        let base = group.action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? group.action
        return ActionLabelCatalog.bundled.shortSummary(forAction: base.trimmingCharacters(in: .whitespaces))
    }

    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Primary: the friendly title (system font, so it reads as a name, not code).
            // The raw action id is demoted to the tooltip (KB-5/CB-7) — off the row but
            // still discoverable on hover, and matched by search regardless.
            Text(friendlyTitle)
                .font(.body)
                .foregroundStyle(group.isUnbound ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(group.action)
            // Secondary: a one-line summary when curated.
            if !actionSummary.isEmpty {
                Text(actionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Badge only when the action *deviates* from its default — a wall of "Default"
            // pills across ~140 rows carries no signal (KB-5, badges = deviations only).
            if let badgeText {
                Pill(text: badgeText, tint: badgeTint, style: .prominent)
            }
        }
        // Collapse the action column's fragments (title, summary, badge) into one VoiceOver
        // element read as name + state — the raw id is a sighted power-user tooltip, so it's
        // dropped from the spoken label (H2). The chord recorders/menu are deliberately
        // outside this element (see body).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(actionColumnA11yLabel)
    }

    /// The action column's VoiceOver reading: friendly name, its one-line summary when
    /// curated, and the spoken state — VoiceOver still hears "No shortcut"/"Default"/
    /// "Customized" even though only deviations show a visible badge.
    private var actionColumnA11yLabel: Text {
        var parts = [friendlyTitle]
        if !actionSummary.isEmpty { parts.append(actionSummary) }
        parts.append(spokenState)
        return Text(parts.joined(separator: ", "))
    }

    // MARK: Origin badge (per action)

    /// Whether the action deviates from Ghostty's defaults — any user addition, override,
    /// or a turned-off default counts.
    private var isCustomized: Bool { group.chords.contains { $0.origin != .default && $0.origin != .unbound } }

    /// The visible badge — nil for an untouched default or an unbound action (no badge;
    /// the empty recorder already reads as "no shortcut"). Only a *deviation* shows.
    private var badgeText: String? { isCustomized ? "Customized" : nil }
    private var badgeTint: Color { .accentColor }

    /// The state VoiceOver announces, whether or not a badge is drawn.
    private var spokenState: String {
        if group.isUnbound { return "No shortcut" }
        return isCustomized ? "Customized" : "Default"
    }

    // MARK: Chord area (capsules + add + menu)

    private var chordArea: some View {
        HStack(spacing: 6) {
            ForEach(group.chords) { chord in
                chordCapsule(chord)
            }
            // An unbound action's single recorder already *is* the "add first shortcut"
            // affordance, so the explicit "+" only appears once the action has a chord.
            if !group.isUnbound {
                addChordButton
            }
            actionsMenu
        }
    }

    @ViewBuilder
    private func chordCapsule(_ chord: MergedKeybind) -> some View {
        if model.isReadOnly(chord) {
            readOnlyCapsule(chord)
        } else {
            switch chord.origin {
            case .unbound:
                recorder(for: chord, width: Self.emptyRecorderWidth)
            case .userDisablesDefault:
                disabledCapsule(chord)
            case .default, .userAdded, .userOverridesDefault:
                editableCapsule(chord)
            }
        }
    }

    /// Fixed widths so an action's chords stay tidy: a bound recorder is compact (glyphs
    /// are short), an empty one is wider to fit its "click or press ⏎" affordance.
    private static let boundRecorderWidth: CGFloat = 108
    private static let emptyRecorderWidth: CGFloat = 168

    private func recorder(for chord: MergedKeybind, width: CGFloat) -> some View {
        KeyRecorderView(
            token: chord.trigger,
            onCapture: { capture($0, edit: .rebind(chord)) },
            onWarning: { warning = $0 }
        )
        .frame(width: width, height: 30)
    }

    /// A default / user / override chord: an inline recorder to re-record it, plus a
    /// remove (default → turn off; user → delete) and a context menu for advanced grammar.
    private func editableCapsule(_ chord: MergedKeybind) -> some View {
        HStack(spacing: 2) {
            recorder(for: chord, width: Self.boundRecorderWidth)
            removeButton(chord)
        }
        .contextMenu {
            Button("Edit as text…") { beginTextEdit(chord) }
        }
    }

    private func removeButton(_ chord: MergedKeybind) -> some View {
        Button {
            removeChord(chord)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .help(removeHelp(chord))
        .accessibilityLabel("\(removeHelp(chord)): \(KeybindTrigger.displaySymbol(for: chord.trigger))")
    }

    private func removeHelp(_ chord: MergedKeybind) -> String {
        chord.origin == .default ? "Turn off this default shortcut" : "Remove this shortcut"
    }

    /// A default the user turned off: struck-through trigger with a one-click re-enable.
    private func disabledCapsule(_ chord: MergedKeybind) -> some View {
        HStack(spacing: 2) {
            triggerPill(chord, strikethrough: true)
            Button {
                perform { await model.removeKeybind(trigger: chord.canonicalTrigger) }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Re-enable this default shortcut")
            .accessibilityLabel("Re-enable \(KeybindTrigger.displaySymbol(for: chord.trigger))")
        }
    }

    /// A chord defined in another file: shown but not editable here (Risk R-F).
    private func readOnlyCapsule(_ chord: MergedKeybind) -> some View {
        HStack(spacing: 4) {
            triggerPill(chord, strikethrough: false)
            if let source = chord.source {
                Image(systemName: "lock")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help("Defined in \((source.file as NSString).lastPathComponent) — edit it there")
                    .accessibilityLabel("Read-only, defined in \((source.file as NSString).lastPathComponent)")
            }
        }
    }

    @ViewBuilder
    private func triggerPill(_ chord: MergedKeybind, strikethrough: Bool) -> some View {
        let physical = KeybindTrigger.isPhysicalNamedKey(chord.trigger)
        Text(KeybindTrigger.displaySymbol(for: chord.trigger))
            // A physical key (the hardware Copy/Paste key) reads as a mono small-caps chip
            // so a lone word doesn't look like prose beside the ⌘⌃⌥⇧ glyph chords (KB-3/CB-6).
            .font(physical ? .system(.caption, design: .monospaced).smallCaps() : .body)
            .foregroundStyle(strikethrough ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .strikethrough(strikethrough, color: .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.standard))
            .help(physical ? "Physical \(KeybindTrigger.displaySymbol(for: chord.trigger).capitalized) key" : "")
    }

    private var addChordButton: some View {
        Button {
            addAnotherDraft = ""
            showingAddAnother = true
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.standard))
        }
        .buttonStyle(.borderless)
        .help("Add another shortcut for \(friendlyTitle)")
        .accessibilityLabel("Add another shortcut for \(friendlyTitle)")
    }

    // MARK: Trailing actions menu (per action)

    private var actionsMenu: some View {
        Menu {
            menuOriginActions
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions for \(friendlyTitle)")
    }

    private var groupHasReadOnly: Bool { group.chords.contains { model.isReadOnly($0) } }
    /// Restore is only offered when the action's customization lives in the writer's
    /// target file — a rebind in an include can't be reverted from here (R-F).
    private var canRestore: Bool { canRestoreDefault && !groupHasReadOnly }

    /// The chords the user can retype as advanced grammar here (editable, in-target).
    private var editableChords: [MergedKeybind] {
        group.chords.filter { !model.isReadOnly($0) && $0.origin != .unbound && $0.origin != .userDisablesDefault }
    }

    /// The ⋯ menu hosts what a capsule can't: advanced trigger grammar (sequences,
    /// prefixes) that recording can't express — for a new chord and for editing an
    /// existing one — plus the action-wide "Restore default".
    @ViewBuilder
    private var menuOriginActions: some View {
        Button(group.isUnbound ? "Bind with text…" : "Add shortcut with text…") {
            addAnotherDraft = ""
            showingAddAnother = true
        }
        ForEach(editableChords) { chord in
            Button("Edit \(KeybindTrigger.displaySymbol(for: chord.trigger)) as text…") { beginTextEdit(chord) }
        }
        if canRestore {
            Divider()
            Button("Restore default") {
                perform { await model.restoreActionToDefault(action: group.action) }
            }
        }
    }

    // MARK: Inline popovers (advanced grammar / extra shortcut)

    private func textEditor(_ chord: MergedKeybind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trigger for \(friendlyTitle)")
                .font(.callout.weight(.semibold)).lineLimit(1)
            TextField("e.g. global:ctrl+a>n", text: $textDraft)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit { commitText(chord) }
            Text("Supports sequences (ctrl+a>n) and prefixes (global:, unconsumed:, all:, performable:).")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { textEditChord = nil }
                Button("Save") { commitText(chord) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(textDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var addAnotherEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Additional shortcut for \(friendlyTitle)")
                .font(.callout.weight(.semibold)).lineLimit(1)
            KeyRecorderView(
                token: "",
                onCapture: { token in showingAddAnother = false; capture(token, edit: .addNew) },
                onWarning: { warning = $0 }
            )
            .frame(height: 30)
            TextField("…or type it (ctrl+a>n, global:…)", text: $addAnotherDraft)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit { commitAddAnother() }
            HStack {
                Spacer()
                Button("Cancel") { showingAddAnother = false }
                Button("Add") { commitAddAnother() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(addAnotherDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func beginTextEdit(_ chord: MergedKeybind) {
        textDraft = chord.trigger
        textEditChord = chord
    }

    private func commitText(_ chord: MergedKeybind) {
        let token = textDraft.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        textEditChord = nil
        capture(token, edit: .rebind(chord))
    }

    private func commitAddAnother() {
        let token = addAnotherDraft.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        showingAddAnother = false
        capture(token, edit: .addNew)
    }

    // MARK: Write actions

    /// The edit a captured chord should perform: re-record an existing chord (or bind an
    /// unbound action), or add an additional chord for the action.
    private enum ChordEdit: Equatable {
        case rebind(MergedKeybind)
        case addNew
    }

    /// A recorded chord and the action it collides with, held while the user chooses
    /// Replace or Cancel (F4).
    private struct PendingConflict: Equatable {
        let token: String
        let conflictingAction: String
        let edit: ChordEdit
    }

    /// Route a captured chord: no-op when re-recording a chord's own keys; hold a conflict
    /// prompt when the chord already drives a *different* action (F4); otherwise commit.
    private func capture(_ token: String, edit: ChordEdit) {
        warning = nil
        let token = token.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        if case .rebind(let chord) = edit, !chord.canonicalTrigger.isEmpty,
           KeybindTrigger.parse(token).canonical() == chord.canonicalTrigger {
            // Re-recording the chord's own current keys — clear any stale conflict prompt.
            pendingConflict = nil
            return
        }
        if let colliding = KeybindMerge.conflictingAction(forTrigger: token,
                                                          excludingAction: group.action,
                                                          in: model.keybindGroups) {
            pendingConflict = PendingConflict(token: token, conflictingAction: colliding, edit: edit)
            return
        }
        performEdit(edit, token: token)
    }

    /// Commit a captured chord — the write path behind both a clean capture and a
    /// "Replace" on a conflict. A default moves to the new keys and disables its old
    /// default; an unbound action gains its first binding; a user chord moves in place; an
    /// additional chord is appended. Any binding already on `token` is overridden (the
    /// write transforms collapse by canonical trigger), which is exactly "Replace".
    private func performEdit(_ edit: ChordEdit, token: String) {
        pendingConflict = nil
        perform {
            switch edit {
            case .rebind(let chord):
                switch chord.origin {
                case .default:
                    await model.rebindDefaultKeybind(oldTrigger: chord.trigger, newTrigger: token, action: group.action)
                case .unbound:
                    await model.applyKeybindEdit(originalTrigger: nil, trigger: token, action: group.action)
                case .userAdded, .userOverridesDefault, .userDisablesDefault:
                    await model.applyKeybindEdit(originalTrigger: chord.canonicalTrigger, trigger: token, action: group.action)
                }
            case .addNew:
                await model.applyKeybindEdit(originalTrigger: nil, trigger: token, action: group.action)
            }
        }
    }

    /// Remove a chord: a default is *turned off* (its trigger is disabled with `=unbind`),
    /// a user chord is deleted (any default it shadowed reactivates).
    private func removeChord(_ chord: MergedKeybind) {
        perform {
            switch chord.origin {
            case .default:
                await model.unbindDefaultKeybind(trigger: chord.canonicalTrigger)
            case .userAdded, .userOverridesDefault:
                await model.removeKeybind(trigger: chord.canonicalTrigger)
            case .userDisablesDefault, .unbound:
                break
            }
        }
    }

    /// Run a model write with a clean apply state so this row's operation isn't shadowed
    /// by stale feedback from a previous edit.
    private func perform(_ work: @escaping () async -> Void) {
        model.resetApplyState()
        Task { await work() }
    }

    // MARK: Conflict prompt

    /// The conflict-at-capture prompt (F4, CONTROLS-10/11): a rebind onto a chord that
    /// already drives a different action asks before stealing it — surfaced *at capture*,
    /// ahead of the after-the-fact lint bar. Two choices: Replace (bind here, overriding
    /// the other) or Cancel. There's no "keep both" — one chord maps to one action, so a
    /// second binding would just be a shadowed duplicate the linter then flags.
    private func conflictPrompt(_ conflict: PendingConflict) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("\(KeybindTrigger.displaySymbol(for: conflict.token)) is already used by \(ActionLabelCatalog.bundled.displayTitle(for: conflict.conflictingAction)).")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Replace") { performEdit(conflict.edit, token: conflict.token) }
                .buttonStyle(.borderedProminent)
            Button("Cancel") { pendingConflict = nil }
                .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}
