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
    /// The selected section-filter pill (D); `nil` = "All". View-local like `filter`, so it
    /// resets when the user navigates to another sidebar surface.
    @State private var selectedSection: String? = nil
    /// A captured chord to search by (D) — the canonical trigger of a shortcut the user
    /// *pressed* rather than typed; `nil` = not chord-searching. Mutually exclusive with the
    /// text `filter` (capturing clears the text).
    @State private var chordFilter: String? = nil

    var body: some View {
        let all = model.keybindGroups
        // The section pills are derived from the *full* set (not the text-filtered one) so the
        // bar stays stable as the user types — one pill per section that actually has actions.
        let sectionItems = ActionCategoryCatalog.bundled.sections(for: all)
            .map { SectionFilterBar.Item(id: $0.id, title: $0.title) }
        // Compose the filters: a captured chord (exact match) OR the text search, then narrow
        // to the selected section. Chord and text are mutually exclusive in the search bar.
        let base = chordFilter.map { KeybindSearch.groups(all, matchingChord: $0) } ?? filtered(all)
        let groups = selectedSection.map { ActionCategoryCatalog.bundled.groups(base, inSection: $0) } ?? base
        // Which base actions carry >1 distinct param, so their param folds into the title
        // (goto_tab:1…8) rather than reading as a lone caption (copy_to_clipboard:mixed).
        // Computed over the *full* set so filtering never changes a row's title (KB-4).
        let foldParams = ActionLabelCatalog.multiParamActions(in: all.map(\.action))
        return VStack(spacing: 0) {
            SurfaceHeader(
                title: OptionCategorizer.keybindingsCategory,
                subtitle: didLoad ? countSummary(all) : nil
            )
            // The search bar: text filter + a "press keys" chord capture (D).
            if didLoad {
                KeybindSearchBar(text: $filter, chord: $chordFilter)
                    .padding(.bottom, DesignTokens.Spacing.standard)
            }
            // A horizontal section filter for quick jumps to a group (D). Only once loaded and
            // when there's more than one section to choose between.
            if didLoad && sectionItems.count > 1 {
                SectionFilterBar(items: sectionItems, selection: $selectedSection)
                    .padding(.bottom, DesignTokens.Spacing.standard)
            }
            keybindHint
            Divider()
            if !didLoad {
                ProgressView("Loading keybindings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                emptyState
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
        // A chord search is a global "what's bound to these keys?" query, so it drops any
        // active section filter (the chord may live in a different section).
        .onChange(of: chordFilter) { _, new in if new != nil { selectedSection = nil } }
    }

    /// The empty result — chord-aware: a pressed combo that matches nothing is *useful*
    /// signal (that shortcut is free), so it says so rather than a generic "no results".
    @ViewBuilder private var emptyState: some View {
        if let chordFilter {
            ContentUnavailableView {
                Label("Nothing uses \(KeybindTrigger.displaySymbol(for: chordFilter))", systemImage: "keyboard")
            } description: {
                Text("That shortcut isn't bound to anything — it's free to use.")
            }
        } else {
            ContentUnavailableView.search(text: filter)
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
        // Read the ~140 actions under curated functional sections instead of one flat wall
        // (KB-9). Sectioning is applied to the *filtered* groups, so a search shows only the
        // sections that still have matches.
        let sections = ActionCategoryCatalog.bundled.sections(for: groups)
        return List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.groups) { group in
                        KeybindRow(group: group,
                                   foldParams: foldParams,
                                   canRestoreDefault: restorable.contains(group.action))
                    }
                } header: {
                    // A prominent group heading (D) — the default List section header reads
                    // too muted to anchor a group. Primary color + headline weight, and
                    // `.textCase(nil)` keeps the curated casing ("Splits", not "SPLITS").
                    Text(section.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
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

/// The Keyboard Shortcuts search bar (D): the usual text filter with a trailing "press keys"
/// button that flips the field into a chord-capture mode, so a shortcut can be found by
/// *pressing* it, not just typing its name. Three states — text / capturing / captured-chord
/// — styled to match the shared `SurfaceSearchField`. The capture reuses the proven
/// `KeyRecorderView` (autostart, so it opens already listening; a click still works if focus
/// didn't land), and hands back the same canonical token the rebind capsules produce.
private struct KeybindSearchBar: View {
    @Binding var text: String
    /// The captured canonical trigger (nil = plain text search). Set on capture, cleared by
    /// the ✕ (or replaced when a fresh capture starts).
    @Binding var chord: String?
    @State private var capturing = false
    @FocusState private var textFocused: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.snug) {
            Image(systemName: (capturing || chord != nil) ? "keyboard" : "magnifyingglass")
                .foregroundStyle(capturing ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .font(.callout)
                .accessibilityHidden(true)
            content
        }
        .padding(.horizontal, DesignTokens.Spacing.cozy)
        .padding(.vertical, DesignTokens.Spacing.snug)
        .background(DesignTokens.subtleFill, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.field))
        .padding(.horizontal, DesignTokens.Spacing.surface)
        // Preserve the ⌘F route (B1): focus this surface's search — dropping any chord capture
        // and returning to the text field.
        .focusedSceneValue(\.focusSurfaceFilter, {
            chord = nil
            capturing = false
            textFocused = true
        })
    }

    @ViewBuilder private var content: some View {
        if capturing {
            Text("Press a shortcut…").foregroundStyle(.secondary)
            KeyRecorderView(token: "", onCapture: { token in
                guard !token.isEmpty else { return }   // Delete clears the recorder; ignore here
                chord = token
                capturing = false
            }, onRecordingChanged: { recording in
                // Recording ending without a capture (Escape, focus loss) exits capture mode
                // rather than stranding the field in a dead "Press a shortcut…" state.
                if !recording { capturing = false }
            }, autostart: true)
            Spacer(minLength: 0)
            clearButton("Cancel") { capturing = false }
        } else if let chord {
            Text(KeybindTrigger.displaySymbol(for: chord))
                .font(.callout.weight(.medium))
                .accessibilityLabel("Searching for the shortcut \(KeybindTrigger.displaySymbol(for: chord))")
            Spacer(minLength: 0)
            clearButton("Clear shortcut search") { self.chord = nil }
        } else {
            TextField("Filter by action or shortcut", text: $text)
                .textFieldStyle(.plain)
                .focused($textFocused)
            if !text.isEmpty {
                clearButton("Clear search") { text = "" }
            }
            Button {
                text = ""
                capturing = true
            } label: {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Search by pressing a shortcut")
            .accessibilityLabel("Search by pressing a shortcut")
        }
    }

    private func clearButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A horizontal layout that wraps its subviews onto additional lines when they don't fit the
/// proposed width, keeping every one visible and reachable — so a keyboard-shortcut row's
/// chords (recorder + remove, the add "+", the ⋯ menu) move to a new line at narrow widths or
/// under large Dynamic Type rather than squeezing the action title off the row (R12,
/// scenario 2/5). Nothing is hidden behind an overflow menu, so Rebind / Disable / Add / More
/// stay reachable at any width. Each line is trailing-aligned so a single-line row keeps the
/// established right-hugging look; the layout fills the width it's offered so that alignment
/// has room to work.
struct ChordFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    /// Break the subviews into lines that each fit `maxWidth`, measuring every subview at its
    /// natural size (chords/menus are content-sized, so `.unspecified` is their intrinsic).
    private func lines(_ subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, projected > maxWidth {
                lines.append(current)
                current = Line(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = projected
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = lines(subviews, maxWidth: maxWidth)
        let contentWidth = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        // Fill a concrete offered width (so trailing alignment has room); report content width
        // only when the proposal is unbounded (a measuring context).
        let width = (maxWidth == .infinity) ? contentWidth : maxWidth
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, maxWidth: bounds.width) {
            var x = bounds.maxX - line.width   // trailing-align each line
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
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
    /// True while any chord in this row is recording — drives the row's recording hint (the
    /// guidance the compact capsule no longer shows). Reading it in the body is also what
    /// re-lays-out the row on the recording toggle, so the recorder's width is always current.
    @State private var isRecordingActive = false
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
            // The action title keeps its width (layoutPriority) and the chords fill the rest,
            // wrapping to a new line at narrow widths (or large Dynamic Type) rather than
            // squeezing the title into truncation (R12, scenario 2/5). The old `Spacer` is
            // gone: the chord area itself fills the trailing space and right-aligns its
            // capsules, so the layout still reads right-hugging while it can now wrap.
            HStack(alignment: .top, spacing: 12) {
                actionColumn
                    .layoutPriority(1)
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
            } else if isRecordingActive {
                // The capsule shows only a compact recording dot now, so the guidance lives
                // here. Reading `isRecordingActive` also re-lays-out the row on the recording
                // toggle, keeping the content-sized recorder's width current (Phase G review).
                Label("Press the new keys — ⌫ clears, esc cancels.", systemImage: "record.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        // The raw action id stays reachable for VoiceOver users who rely on it — surfaced as
        // on-demand custom content (VO rotor) rather than spoken on every row (U26/GAP-3).
        .accessibilityCustomContent("Action ID", group.action)
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
        // A wrapping layout (not an `HStack`) so many chords + the add "+" + the ⋯ menu flow
        // onto a second line at narrow widths instead of stealing the action title's room
        // (R12, scenario 2/5). Every control stays present and reachable — nothing collapses
        // into a hidden overflow.
        ChordFlowLayout(spacing: 6, lineSpacing: 6) {
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
        let readOnly = model.isReadOnly(chord)
        switch chord.origin {
        case .userDisablesDefault:
            // A turned-off default reads struck-through even when the unbind lives in an
            // included file — checked *before* read-only, so a read-only unbind isn't
            // rendered as a normal locked pill that looks bound. Re-enable is offered only
            // when it's editable here; a read-only one shows where it's turned off instead.
            disabledCapsule(chord, readOnly: readOnly)
        case .unbound:
            // An unbound placeholder has no source, so it's never read-only.
            recorder(for: chord)
        case .default, .userAdded, .userOverridesDefault:
            if readOnly { readOnlyCapsule(chord) } else { editableCapsule(chord) }
        }
    }

    private func recorder(for chord: MergedKeybind) -> some View {
        KeyRecorderView(
            token: chord.trigger,
            onCapture: { capture($0, edit: .rebind(chord)) },
            onWarning: { warning = $0 },
            onRecordingChanged: { isRecordingActive = $0 }
        )
        // Content-sized (U27): a ⌘n chip stays ~50pt (not a fixed 108) so two-chord rows
        // keep the action title readable at the minimum window width. Height stays 30.
        .frame(height: 30)
    }

    /// A default / user / override chord: an inline recorder to re-record it, plus a
    /// remove (default → turn off; user → delete) and a context menu for advanced grammar.
    private func editableCapsule(_ chord: MergedKeybind) -> some View {
        HStack(spacing: 2) {
            recorder(for: chord)
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

    /// A default the user turned off: struck-through trigger. When the unbind lives in the
    /// writer's target file it carries a one-click re-enable; when it's turned off in an
    /// included file it shows a lock naming that file (it can't be re-enabled from here).
    @ViewBuilder
    private func disabledCapsule(_ chord: MergedKeybind, readOnly: Bool) -> some View {
        HStack(spacing: 2) {
            triggerPill(chord, strikethrough: true)
            if readOnly {
                if let source = chord.source {
                    Image(systemName: "lock")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help("Turned off in \((source.file as NSString).lastPathComponent) — edit it there")
                        .accessibilityLabel("Turned off in \((source.file as NSString).lastPathComponent)")
                }
            } else {
                Button {
                    perform { await model.removeKeybind(trigger: chord.canonicalTrigger, alsoRemove: chord.companions) }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Re-enable this default shortcut")
                .accessibilityLabel("Re-enable \(KeybindTrigger.displaySymbol(for: chord.trigger))")
            }
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
        let newCanonical = KeybindTrigger.parse(token).canonical()

        // The chord being re-recorded, if any: its own keys are a no-op, and it's excluded
        // from the "this action already uses these keys" check below.
        let editingCanonical: String?
        if case .rebind(let chord) = edit { editingCanonical = chord.canonicalTrigger } else { editingCanonical = nil }

        // Re-recording a chord's own current keys — clear any stale conflict prompt.
        if let editingCanonical, !editingCanonical.isEmpty, newCanonical == editingCanonical {
            pendingConflict = nil
            return
        }
        // These keys are already one of THIS action's live chords. `conflictingAction`
        // excludes the action itself, so it wouldn't catch this — but committing would
        // silently collapse two of the action's shortcuts into one (rebind) or write a
        // redundant duplicate (add). Warn softly and don't merge (adversarial finding).
        if group.chords.contains(where: {
            $0.canonicalTrigger == newCanonical
                && $0.canonicalTrigger != editingCanonical
                && $0.origin != .unbound && $0.origin != .userDisablesDefault
        }) {
            warning = "\(friendlyTitle) already uses \(KeybindTrigger.displaySymbol(for: token))."
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
                    await model.rebindDefaultKeybind(oldTrigger: chord.trigger, newTrigger: token, action: group.action, alsoUnbind: chord.companions)
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
                await model.unbindDefaultKeybind(trigger: chord.canonicalTrigger, alsoUnbind: chord.companions)
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
