import SwiftUI
import AppKit
import GhosttyConfigKit

/// The main column: a searchable list of options for the current selection.
/// Each row edits its option inline (U7), so there is no separate detail pane —
/// the value control lives on the row and the fuller docs/metadata/actions live
/// in a popover behind the row's info button.
struct OptionListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingReset = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // The shared header owns the search field now (moved off the toolbar's
            // `.searchable`), so search sits in the same place on every surface (C3).
            SurfaceHeader(
                title: title,
                subtitle: headerSubtitle,
                searchText: $model.query,
                searchPrompt: "Search options or describe a behavior"
            )
            Divider()
            statusBackLink
            appearanceCrossLink
            // A ScrollViewReader lets a `focus(optionNamed:)` deep-link (from a global
            // Find result, and later Customized/Problems) scroll its target into view.
            // Gated on `pendingFocusScroll` so it fires only for an explicit focus — via
            // `onChange` when the list is already mounted (a Customized deep-link), and
            // via `onAppear` when the list remounts (a Find result swaps Find out and the
            // list in, so `onChange` never sees the change) (D1/D2).
            ScrollViewReader { proxy in
                content
                    .onAppear { scrollToFocusTarget(proxy) }
                    .onChange(of: model.focusRequestID) { _, _ in scrollToFocusTarget(proxy) }
            }
            // Reset-all is a batch op with no per-row anchor (`applyingOptionName == nil`),
            // so its Saved · Undo / error feedback shows in a surface bar here instead of on
            // a row (G4). Per-row edits keep `applyingOptionName` set, so this stays hidden
            // for them and the per-row feedback is the single source.
            if model.applyingOptionName == nil {
                SurfaceFeedbackBar(applyState: model.applyState)
            }
        }
        .navigationSplitViewColumnWidth(min: 360, ideal: 460)
        .confirmationDialog(
            "Reset all settings to their defaults?",
            isPresented: $confirmingReset, titleVisibility: .visible
        ) {
            Button("Reset \(model.resettableCount) Setting\(model.resettableCount == 1 ? "" : "s")", role: .destructive) {
                Task { await model.resetAllCustomized() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every option you've customized returns to its default. Your current config is backed up first, and you can undo this with ⌘Z.")
        }
    }

    @ViewBuilder
    private var statusBackLink: some View {
        if model.selection == .customized {
            StatusBackLink()
        }
    }

    /// On the Appearance surface, a one-line cross-link clarifying that colors come from
    /// the active theme, with a jump to the Themes browser (D1). Hidden elsewhere and
    /// while searching (the note is category context, not a search result).
    @ViewBuilder
    private var appearanceCrossLink: some View {
        if case .category(OptionCategorizer.appearanceCategory) = model.selection,
           model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "paintpalette")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Colors come from your theme — override individual colors here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Set one in Themes →") { model.selection = .themes }
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))
        }
    }

    /// Scroll a pending `focus(optionNamed:)` target into view, then clear the flag so
    /// it fires exactly once per focus and never on ordinary navigation. Deferred one
    /// runloop so a freshly-navigated category has laid out its rows first.
    private func scrollToFocusTarget(_ proxy: ScrollViewProxy) {
        guard model.pendingFocusScroll, let name = model.selectedOptionName else { return }
        DispatchQueue.main.async {
            if reduceMotion {
                proxy.scrollTo(name, anchor: .center)
            } else {
                withAnimation { proxy.scrollTo(name, anchor: .center) }
            }
            model.pendingFocusScroll = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.browser == nil {
            ProgressView("Loading catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleOptions.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.showsSplitSections {
            // A browsed category splits into a Common section and a collapsible
            // Advanced section (B1); the subview owns the per-category
            // expand/collapse state, keyed so each category remembers its own.
            // `.id(categoryName)` gives each category a distinct view identity, so
            // its `@AppStorage("advancedExpanded.<category>")` is re-initialized per
            // category instead of staying pinned to the first one shown.
            CategoryOptionList(category: categoryName)
                .id(categoryName)
        } else if isSearching {
            // Search can return hundreds of ranked hits (name + intent + full-text
            // documentation match), so it uses a **virtualized List** — a grouped Form
            // builds every row eagerly and would jank the main thread on a broad query.
            List(model.visibleOptions) { option in
                OptionRow(option: option)
            }
        } else {
            // The Customized surface is bounded (only options the user changed), so it
            // keeps the grouped-Form cards to match the browsed categories.
            Form {
                Section {
                    ForEach(model.visibleOptions) { option in
                        customizedRow(option)
                    }
                }
                // Reset everything back to defaults in one undoable step (G4), only on the
                // Customized surface where "everything you changed" is the list you see. A
                // grouped Form drops `role:`-only red styling, so render via
                // DestructiveRowButton for explicit red (DS-7).
                if model.selection == .customized && model.resettableCount > 0 {
                    Section {
                        DestructiveRowButton(title: "Reset All to Defaults…") { confirmingReset = true }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// A row on the Customized surface. The two flagship keys with a rich dedicated
    /// editor deep-link to it instead of dead-ending on a raw token (F3): `theme` →
    /// the Themes browser, `keybind` → the Keyboard Shortcuts surface. Everything else
    /// edits inline as usual. Only applied on the Customized surface — the plain `.none`
    /// fallback and search results still render ordinary rows.
    @ViewBuilder
    private func customizedRow(_ option: MergedOption) -> some View {
        if model.selection == .customized, option.option.name == "theme" {
            DeepLinkRow(
                title: LabelCatalog.bundled.displayTitle(for: "theme"),
                value: model.currentTheme ?? "",
                linkLabel: "Edit in Themes",
                systemImage: "paintpalette",
                action: { model.focus(optionNamed: "theme") }
            )
        } else if model.selection == .customized, option.option.name == "keybind" {
            DeepLinkRow(
                title: OptionCategorizer.keybindingsCategory,
                subtitle: customizedKeybindSummary(option),
                linkLabel: "Edit in Keyboard Shortcuts",
                systemImage: "keyboard",
                action: { model.focus(optionNamed: "keybind") }
            )
        } else {
            OptionRow(option: option)
        }
    }

    /// "N shortcuts customized" for the keybind deep-link — the count of the user's own
    /// per-trigger `keybind` lines (each binding, including a disabled default). Uses the
    /// kit parser so whole-value specials like `clear` — which aren't per-trigger bindings
    /// and never appear as editor rows — don't inflate the count (review F #3).
    private func customizedKeybindSummary(_ option: MergedOption) -> String {
        let n = KeybindMerge.userBindings(values: option.userValues, sources: option.sources).count
        return "\(n) shortcut\(n == 1 ? "" : "s") customized"
    }

    /// True when a search query is active — the flat, ranked-results branch.
    private var isSearching: Bool {
        !model.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A secondary count line for the header — the result count while searching, or the
    /// number of customized options on the Customized surface. Nil (hidden) otherwise.
    private var headerSubtitle: String? {
        guard model.browser != nil else { return nil }
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            let n = model.visibleOptions.count
            return "\(n) result\(n == 1 ? "" : "s")"
        }
        if model.selection == .customized {
            let n = model.visibleOptions.count
            return n == 0 ? nil : "\(n) customized"
        }
        return nil
    }

    private var title: String {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty { return "Search" }
        switch model.selection {
        case .category(let c): return c
        case .customized: return "Customized"
        case .problems: return "Problems"
        case .themes: return "Themes"
        case .recommended: return "Recommended" // rendered by RecommendedView; here for exhaustiveness
        case .status: return "Status" // rendered by StatusView; here for exhaustiveness
        case .none: return "Options"
        }
    }

    /// The category name for the split-section list; only read when
    /// `showsSplitSections` is true (a category is selected with no active search).
    private var categoryName: String {
        if case .category(let c) = model.selection { return c }
        return ""
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else if model.selection == .customized {
            customizedSpringboard
        } else {
            ContentUnavailableView("No options",
                                   systemImage: "tray",
                                   description: Text("Nothing to show for this selection."))
        }
    }

    /// The empty-Customized state as a springboard (F3): instead of a dead-end "nothing
    /// here", offer the three next steps a newcomer actually wants — reusing the same
    /// jump-in destinations as the welcome pane so the vocabulary stays consistent.
    private var customizedSpringboard: some View {
        VStack(spacing: 18) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Nothing customized yet").font(.title3.weight(.semibold))
                Text("Changes you make show up here. Start with one of these:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                SpringboardCard(title: "Browse recommended", systemImage: "sparkles") { model.selection = .recommended }
                SpringboardCard(title: "Pick a theme", systemImage: "paintpalette") { model.selection = .themes }
                SpringboardCard(title: "Describe a change", systemImage: "magnifyingglass") { model.beginFind() }
            }
            .frame(maxWidth: 320)
        }
        .padding(40)
    }
}

/// A browsed category rendered as a **Common** section over a collapsible
/// **Advanced (N)** section (B1, IA-2). Newcomer-frequent options sit up top; the
/// long tail is tucked behind a disclosure that's collapsed by default, with its
/// expanded state persisted per category so each one remembers how you left it.
///
/// When a category is *entirely* advanced (e.g. the "Advanced" category itself),
/// there's nothing to tuck behind, so its options render as a plain list rather
/// than hiding everything under a collapsed disclosure.
private struct CategoryOptionList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let category: String
    @AppStorage private var advancedExpanded: Bool

    init(category: String) {
        self.category = category
        _advancedExpanded = AppStorage(wrappedValue: false, "advancedExpanded.\(category)")
    }

    var body: some View {
        let common = model.commonOptions
        let advanced = model.advancedOptions
        Form {
            if !common.isEmpty {
                Section {
                    rows(common)
                } header: {
                    // Only label it "Common" when there's an Advanced section to
                    // contrast with; a lone section needs no header.
                    if !advanced.isEmpty { Text("Common") }
                }
            }
            if !advanced.isEmpty {
                if common.isEmpty {
                    // Whole category is advanced — show it flat, never collapsed away.
                    Section { rows(advanced) }
                } else {
                    // Grouped-Form Sections don't collapse natively (and the native
                    // collapsible section renders no disclosure control here — it
                    // silently trapped the Advanced options, caught in live testing),
                    // so the disclosure is a custom tappable section header with the
                    // rows conditionally rendered in the card below it.
                    Section {
                        if advancedExpanded {
                            // Try a fade on the revealed rows (MO-4/CB-12). Grouped-Form
                            // Sections are documented-fragile with insertions, so this may
                            // resolve to instant appearance — which is fine: the rotating
                            // chevron is the honest cue either way (never removed).
                            rows(advanced)
                                .transition(.opacity)
                        }
                    } header: {
                        advancedHeader(count: advanced.count)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // A `focus(optionNamed:)` deep-link to an *advanced* option would land behind a
        // collapsed disclosure and never scroll into view — so expand Advanced when the
        // focus target lives there (D1). On appear too, so a focus that navigates into
        // this category (mounting a fresh list) still reveals the target.
        .onAppear { expandAdvancedIfFocusTargetIsAdvanced() }
        .onChange(of: model.focusRequestID) { _, _ in expandAdvancedIfFocusTargetIsAdvanced() }
    }

    private func expandAdvancedIfFocusTargetIsAdvanced() {
        guard let name = model.selectedOptionName else { return }
        if model.advancedOptions.contains(where: { $0.option.name == name }) {
            advancedExpanded = true
        }
    }

    private func advancedHeader(count: Int) -> some View {
        Button {
            // One motion helper for the whole app (U2): reduce-motion resolves to
            // `withAnimation(nil)` — an instant toggle — through the same gate.
            withAnimation(MotionSystem.gated(MotionSystem.quickFade, reduceMotion: reduceMotion)) {
                advancedExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                Text("Advanced (\(count))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverAffordanceButtonStyle(
            cornerRadius: DesignTokens.Radius.standard,
            insets: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8),
            pointingHand: true))
        .accessibilityLabel("Advanced, \(count) options")
        .accessibilityValue(advancedExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Show or hide advanced options")
    }

    private func rows(_ options: [MergedOption]) -> some View {
        ForEach(options) { option in
            OptionRow(option: option)
        }
    }
}

/// One row in the option list: a state dot, the option's name and default, the
/// inline editing control, and an info button that reveals the fuller docs,
/// metadata, and actions in a popover. Apply feedback (saving/saved/error) is
/// shown inline beneath the row while this option is the one being written.
struct OptionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingInfo = false
    @State private var isHovering = false
    let option: MergedOption

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.option.displayTitle)
                        .font(RowMetrics.titleFont)
                        // The raw key is demoted to the popover (and search, R8); a
                        // hover tooltip keeps it a keystroke away for power users.
                        .help(option.option.name)
                        // Speak the merged state (A5's one vocabulary) alongside the
                        // name, so VoiceOver conveys what the state dot shows sighted
                        // users — for every state, including the dot-less ones.
                        .accessibilityValue(Text(option.state.displayName))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(RowMetrics.subtitleFont)
                            .foregroundStyle(.secondary)
                            // The row owns truncation now (CM-7): the summary arrives
                            // uncapped and wraps to at most two lines rather than being
                            // ellipsized mid-word by the kit.
                            .lineLimit(1...2)
                            .help(subtitle)
                    }
                }
                // `layoutPriority(1)` so the label claims its natural width first and a
                // title never wraps to make room for the accessory (DS-9).
                .layoutPriority(1)
                // MO-6: the state cue scales in/out when a value is customized or reset —
                // keyed to `option.state` only, so the hover dot↔reset swap stays instant.
                stateAccessory
                    .animation(MotionSystem.gated(MotionSystem.settle, reduceMotion: reduceMotion),
                               value: option.state)
                Spacer(minLength: 12)
                editor
                infoButton
            }
            OptionRowFeedback(option: option)
        }
        .padding(.vertical, RowMetrics.rowVerticalPadding)
        .onHover { isHovering = $0 }
    }

    /// The customized-state cue (U5, DS-5/DS-9/DS-11) — replacing the accent
    /// "Customized" pill + reset cluster that squeezed labels and repeated to noise.
    /// A small **non-accent** state dot at rest (KTD4), in a fixed-width slot so it
    /// never shifts the row (width-stable), that strengthens into an inline reset
    /// glyph on hover. The dot is suppressed on the Customized surface — where every
    /// row is customized, a per-row dot is redundant (IA-8) — but the hover reset
    /// stays. Reset is *always* reachable without hovering via the ⓘ popover (a named
    /// VoiceOver action), so hover reveals nothing otherwise-invisible: it only makes
    /// the already-visible state actionable (KTD5). Rendered only on customized rows;
    /// default/unset rows add no slot.
    @ViewBuilder
    private var stateAccessory: some View {
        if option.state == .setNonDefault {
            ZStack {
                if isHovering {
                    Button {
                        Task { await model.applyEdit(option: option, values: []) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .imageScale(.medium)
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverAffordanceButtonStyle.icon)
                    .help("Reset to default")
                    .accessibilityLabel("Reset \(option.option.displayTitle) to default")
                } else if model.selection != .customized {
                    Circle()
                        .fill(DesignTokens.customizedTint)
                        .frame(width: 8, height: 8)
                        // The title already announces the state; the dot is its visual echo.
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 22, height: 22)   // width-stable: dot ↔ reset never shifts the row
            // MO-6: the same scale-in the theme "Current" pill uses, so both state cues
            // read consistently. Driven by the `.animation(value: option.state)` above.
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    /// Repeatable keys (keybind, palette, …) can't be edited from a single inline
    /// control, so those rows show no editor — their values are summarised in the
    /// subtitle and edited via "Reveal in editor" in the info popover.
    ///
    /// `font-family` and its bold/italic variants are the exception: they're
    /// repeatable (primary + fallbacks, e.g. a Nerd Font for icons), but a font is
    /// something you pick from a list, so they get a dedicated font picker instead.
    /// Repeatable keys that get a dedicated multi-value editor (B8). `config-file`
    /// stays plain advanced text — a generic list editor would invite arbitrary
    /// includes the reader follows (out of scope). `keybind` is edited on its own
    /// surface, not here.
    private static let listEditorOptions: Set<String> = ["env"]

    @ViewBuilder
    private var editor: some View {
        if option.option.name.hasPrefix("font-family") {
            FontFamilyEditor(option: option)
        } else if option.option.name == "palette" {
            PaletteEditor(option: option)
        } else if option.option.name == "font-feature" {
            // Toggle-first Ligatures control (U8), with the generic per-tag list demoted
            // to a "Customize…" disclosure for stylistic sets.
            FontFeatureEditor(option: option)
        } else if Self.listEditorOptions.contains(option.option.name) {
            ListValueEditor(option: option)
        } else if !option.option.isRepeatable {
            InlineOptionEditor(option: option)
        }
    }

    private var infoButton: some View {
        Button {
            showingInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                // ~28pt hit target so the info affordance is comfortably tappable
                // (A11Y-10) — the bare glyph was a ~16pt target.
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverAffordanceButtonStyle.icon)
        .help(docHelp)
        .accessibilityLabel("Info for \(option.option.name)")
        .popover(isPresented: $showingInfo, arrowEdge: .trailing) {
            OptionInfoPopover(option: option)
        }
        // One click to close-and-act: dismissing the popover by clicking elsewhere (a
        // sidebar row, another control) shouldn't cost a wasted first click (U11/MO-1).
        .passthroughPopoverDismiss(isPresented: $showingInfo)
    }

    private var docHelp: String {
        let doc = option.option.documentation
        return doc.isEmpty ? "No documentation available." : doc
    }

    /// A plain-language one-line description of what the option does (A1). The
    /// default/value context that used to live here ("default: X" / "no default" /
    /// "default: default") now lives in the info popover, so the row reads as
    /// name + purpose. Empty when the catalog has no summary, and the line is then
    /// hidden rather than showing filler. Uncapped (CM-7): the row's `lineLimit(1...2)`
    /// owns truncation, so a real sentence wraps rather than ellipsizing mid-word.
    private var subtitle: String {
        option.option.subtitleSummary
    }
}

/// Per-row apply feedback (U6, MO-2). Shown only while this option is the one being
/// written (`applyingOptionName`), so a single global apply state never decorates the
/// wrong row. Three behaviors the old inline block lacked:
///  - the settled feedback **fades in** under the row (`MotionSystem.quickFade` + a
///    slide from the top); `.applying` appears instantly so "Saving…" doesn't flicker;
///  - after ~2.5s untouched a *saved* result **collapses to a small static checkmark**,
///    so the rows below return to place instead of being shoved permanently — ⌘Z stays
///    the durable undo (a failure never collapses; it holds until the next edit);
///  - a brief inline **Undo** (after a save) / **Redo** (after a revert) rides along
///    until the collapse — the time-boxed single-step redo (U6 decision).
/// The collapse timer keys on `applyState`: every settle is preceded by `.applying`, so
/// the id always changes between outcomes and the 2.5s window restarts each edit.
private struct OptionRowFeedback: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let option: MergedOption
    @State private var collapsed = false

    private var isActiveRow: Bool { model.applyingOptionName == option.option.name }

    var body: some View {
        Group {
            if isActiveRow {
                content
                    .padding(.leading, 15)
            }
        }
        .animation(MotionSystem.gated(MotionSystem.quickFade, reduceMotion: reduceMotion),
                   value: model.applyState.isSettled)
        .task(id: model.applyState) { await runCollapseTimer() }
    }

    @ViewBuilder private var content: some View {
        switch model.applyState {
        case .idle:
            EmptyView()
        case .applying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Saving…").font(.caption2).foregroundStyle(.secondary)
            }
        case .succeeded(let headline, _, _, _):
            succeeded(headline: headline)
                .transition(.opacity.combined(with: .move(edge: .top)))
        case .failed(_, let offersReload):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ApplyFeedbackContent(state: model.applyState)
                // Stale-on-disk is the one failure a reload fixes — offer it inline right
                // where the error shows, so "reload and try again" is one click (G3).
                if offersReload {
                    Button("Reload") { Task { await model.reloadFromDisk() } }
                        .buttonStyle(.link).font(.caption2)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder private func succeeded(headline: String) -> some View {
        if collapsed {
            // Collapsed: a small static checkmark, so the rows below return to place. The
            // headline is its accessibility label so VoiceOver still says Saved/Reverted.
            Image(systemName: model.applyState.feedbackSymbol)
                .foregroundStyle(model.applyState.feedbackTint)
                .font(.caption)
                .accessibilityLabel(headline)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ApplyFeedbackContent(state: model.applyState)
                if model.canUndo {
                    Button("Undo") { Task { await model.undoLastApply() } }
                        .buttonStyle(.link).font(.caption2)
                } else if model.canRedoApply {
                    Button("Redo") { Task { await model.redoLastApply() } }
                        .buttonStyle(.link).font(.caption2)
                }
            }
        }
    }

    /// Reset on every state change, then — only for *this* row's saved result — wait
    /// ~2.5s and collapse. Cancelled and restarted whenever `applyState` changes (the
    /// `.task(id:)` identity), so a new edit reopens the full feedback.
    private func runCollapseTimer() async {
        collapsed = false
        guard isActiveRow, case .succeeded = model.applyState else { return }
        try? await Task.sleep(for: .seconds(2.5))
        guard !Task.isCancelled else { return }
        withAnimation(MotionSystem.gated(MotionSystem.quickFade, reduceMotion: reduceMotion)) {
            collapsed = true
        }
    }
}

// MARK: - Inline editor (U7)

/// A type-appropriate editing control rendered directly on the row. Discrete
/// controls (toggle, dropdown, stepper) apply immediately on change; free-text
/// commits on Return. Every write is validated against the live binary by the
/// model, so on failure the control snaps back to the value that's actually saved.
/// The shared VoiceOver label for an option's inline control: name + default + state,
/// so a control announced on its own (a VO user swiping controls, not row titles) still
/// conveys everything the sighted row shows — the plan's "Font size, default 13,
/// customized" (H1, A11Y-1/2/17). The control's own trait adds the type ("text field")
/// and its live value is the `accessibilityValue`. Used across every editor struct so the
/// announcement is identical whichever control renders.
func optionControlA11yLabel(_ option: MergedOption) -> Text {
    var parts = [option.option.displayTitle]
    let presentation = option.valuePresentation
    switch presentation.origin {
    case .explicitValue:
        parts.append(option.state == .setToDefault ? "explicitly set to default" : "customized")
    case .defaultValue:
        if let value = presentation.value {
            let display = value == "true" ? "On" : (value == "false" ? "Off" : value)
            parts.append("default \(display)")
        }
    case .unresolvedDefault:
        parts.append("default value not documented")
    }
    return Text(parts.joined(separator: ", "))
}

private struct InlineOptionEditor: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption
    @State private var draft: String = ""
    /// Drives the color-editing popover anchored to the row's swatch.
    @State private var showingColorPopover = false
    /// The color value already written in this popover session, so committing on
    /// close doesn't re-write a value a preset/Set/wheel already saved (B6).
    @State private var committedColor: String = ""
    /// Drives the wide multi-line editor for long scalar values (B7).
    @State private var showingLongEditor = false
    /// Tracks the inline free-text field's focus so a blurred, dirty field commits
    /// instead of silently reverting (B7).
    @FocusState private var textFieldFocused: Bool

    /// Long scalar options whose value is awkward in a 160pt field — edited in a wide
    /// multi-line popover instead (B7). `config-file` / `font-feature` are *repeatable*
    /// and handled by their own editors (B8), so they're deliberately absent here.
    private static let longValueOptions: Set<String> = [
        "command", "initial-command", "working-directory", "custom-shader",
    ]

    var body: some View {
        control
            .disabled(isApplyingThis)
            .onAppear { draft = currentValue }
            // The row view is reused across list rebuilds (keyed by option name),
            // so `onAppear` won't fire again after a value changes on disk — resync
            // the draft here instead. `currentValue` only changes once a write has
            // actually landed (an apply, an undo, or an external reload), which is
            // exactly when the control should follow it — so resync unconditionally.
            // (Guarding this on "not mid-apply" was wrong: during an undo the value
            // updates while `applyState` is still `.applying`, so the guard swallowed
            // the one change that mattered and the control kept the stale value.)
            .onChange(of: currentValue) { _, newValue in
                draft = newValue
            }
    }

    @ViewBuilder
    private var control: some View {
        if option.option.isBooleanish {
            // "Boolean impostors" (accept true/false alongside richer values) render
            // toggle-first regardless of their inferred type, so the on/off axis is a
            // switch, not a text box reading `false` (B4).
            BooleanishEditor(
                option: option,
                savedValue: currentValue,
                apply: { apply($0) },
                reset: { Task { await model.applyEdit(option: option, values: []) } }
            )
        } else {
            typedControl
        }
    }

    @ViewBuilder
    private var typedControl: some View {
        switch option.option.valueType {
        case .boolean:
            Toggle("", isOn: boolBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)   // matched to sibling controls (was .mini) (B4)
                .accessibilityLabel(optionControlA11yLabel(option))
        case .enumeration:
            // Rows come from the kit helper (not raw enumValues) so a saved
            // out-of-enum value stays selectable and is never silently dropped.
            // Seed from `currentValue` (the saved value), never `draft`.
            Picker("", selection: enumBinding) {
                ForEach(option.enumChoices(current: currentValue)) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            // Cap + right-align instead of `.fixedSize()`: in the grouped Form's
            // constrained trailing slot a fixed-size menu grew to its longest value
            // and overflowed the card; a bounded frame truncates the label instead.
            .frame(maxWidth: 220, alignment: .trailing)
            .accessibilityLabel(optionControlA11yLabel(option))
        case .number:
            NumericOptionEditor(
                option: option,
                draft: $draft,
                savedValue: currentValue,
                placeholder: fieldPlaceholder,
                apply: { apply($0) }
            )
        case .color:
            // The swatch opens our own color popover — anchored to the row, and with
            // a text input built in so any value Ghostty accepts (hex, an X11 name,
            // or cell-foreground / cell-background) is resolvable in the same place
            // you pick one visually. We roll our own because the system's color well
            // popover is closed (no text field) and SwiftUI's ColorPicker floats the
            // shared panel at a screen corner.
            Button { showingColorPopover.toggle() } label: { swatch }
                .buttonStyle(.plain)
                .help("Edit color")
                // A swatch is pure color — VoiceOver would otherwise announce nothing but
                // "button", so name+state+the color value are made explicit here (H1).
                .accessibilityLabel(optionControlA11yLabel(option))
                .accessibilityValue(Text(currentValue.isEmpty ? "not set" : currentValue))
                .popover(isPresented: $showingColorPopover, arrowEdge: .bottom) {
                    colorEditor
                }
                // Seed the draft from the saved value each time the popover opens, so
                // it never shows a stale (or first-open empty) value. On close, commit
                // whatever the wheel/hex field left in the draft (B6: commit-on-blur),
                // deduped against what a preset/Set already wrote this session.
                .onChange(of: showingColorPopover) { _, isOpen in
                    if isOpen {
                        draft = currentValue
                        committedColor = currentValue
                    } else {
                        requestColorApply(draft)
                    }
                }
        default:
            if Self.longValueOptions.contains(option.option.name) {
                longValueButton
            } else {
                freeTextField
            }
        }
    }

    /// The inline free-text field for ordinary scalar values. Commits on Return *and*
    /// on focus-loss (a blurred, dirty field saves rather than silently reverting),
    /// with a subtle "Return to save" hint while dirty (B7). A full-value tooltip
    /// covers the truncation at 160pt.
    private var freeTextField: some View {
        VStack(alignment: .trailing, spacing: 1) {
            // In a Form the title arg renders as a visible label, so the placeholder
            // moves to `prompt:` and the (empty) label is hidden — otherwise every
            // field shows its placeholder as a stray label beside the value.
            TextField("", text: $draft, prompt: Text(fieldPlaceholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .focused($textFieldFocused)
                // Resign on Return (rather than commit-in-place): committing on blur is
                // the single write path, and resigning clears the field editor's undo
                // stack so a following ⌘Z targets the config revert (undoLastApply), not
                // the just-typed text — otherwise smart ⌘Z can't undo a text-option write
                // while the field stays focused (adversarial review #2).
                .onSubmit { textFieldFocused = false }
                .help(currentValue.isEmpty ? "" : currentValue)
                .accessibilityLabel(optionControlA11yLabel(option))
            if isDirty {
                Text("Return to save").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: textFieldFocused) { _, focused in
            if !focused { commit() }   // commit-on-blur
        }
    }

    /// For long scalar values, an "Edit…" button opening a wide, monospaced,
    /// multi-line-tolerant editor showing the whole value — no more squinting at a
    /// truncated 160pt field (B7).
    private var longValueButton: some View {
        Button { showingLongEditor.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "pencil").imageScale(.small)
                Text(currentValue.isEmpty ? "Set…" : "Edit…")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(currentValue.isEmpty ? "Set a value" : currentValue)
        .accessibilityLabel(Text("Edit \(option.option.displayTitle)"))
        .accessibilityValue(Text(currentValue.isEmpty ? "not set" : currentValue))
        .popover(isPresented: $showingLongEditor, arrowEdge: .bottom) { longValueEditor }
        .onChange(of: showingLongEditor) { _, open in
            if open { draft = currentValue } else { commit() }   // commit on close
        }
    }

    private var longValueEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(option.option.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
            TextField(fieldPlaceholder, text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .lineLimit(3...10)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Done") { showingLongEditor = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 384)
    }

    /// True when the field holds an unsaved edit — drives the "Return to save" hint.
    private var isDirty: Bool { draft != currentValue }

    private var currentValue: String {
        option.valuePresentation.value ?? ""
    }

    /// A hint for an empty field, via the shared kit fallback (CV-7): a docs example for
    /// untyped/text options → the default value → a title-derived "Enter a …" prompt —
    /// never a bare "value". Example-mining is limited to untyped/text options so a
    /// number field doesn't borrow a stray backtick token.
    private var fieldPlaceholder: String {
        let mine = option.option.valueType == .unknown || option.option.valueType == .string
        return LabelCatalog.fieldPlaceholder(
            name: option.option.name,
            title: option.option.displayTitle,
            documentation: option.option.documentation,
            defaultValue: option.option.defaultValue,
            mineExample: mine
        )
    }

    private var isApplyingThis: Bool {
        model.applyingOptionName == option.option.name && model.applyState == .applying
    }

    /// Commit the free-text draft, but only when it actually differs from the
    /// saved value — Return on an unchanged field is a no-op, not a redundant write.
    private func commit() {
        guard draft != currentValue else { return }
        apply(draft)
    }

    private func apply(_ value: String) {
        Task {
            await model.applyEdit(option: option, values: [value])
            // A rejected write never touched disk, so the option still holds its
            // old value — snap the control back to it rather than leave the failed
            // value showing as if it stuck.
            if case .failed = model.applyState { draft = currentValue }
        }
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { draft == "true" },
            set: { newValue in
                let text = newValue ? "true" : "false"
                draft = text
                apply(text)
            }
        )
    }

    private var enumBinding: Binding<String> {
        Binding(
            get: { draft },
            set: { newValue in
                draft = newValue
                apply(newValue)
            }
        )
    }

    // MARK: Color editing

    /// The row's color chip: the saved color as a fill, a *labeled* chip for values a
    /// swatch can't render (an X11 name, `cell-foreground` / `cell-background`), or a
    /// neutral fill only when truly unset — so a named value never reads as empty (B6).
    private var swatch: some View {
        colorFill(currentValue)
            .frame(width: 44, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay { swatchRing(cornerRadius: 5) }
            .contentShape(RoundedRectangle(cornerRadius: 5))
    }

    /// A fill for a color value: the resolved color when it's a hex the swatch can
    /// render; otherwise a labeled chip showing the token (X11 name / `cell-*`) so it
    /// reads as *set to something*; and only a neutral gray when the value is empty.
    @ViewBuilder
    private func colorFill(_ value: String) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let color = Color(hex: value) {
            color
        } else if !trimmed.isEmpty {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Text(trimmed)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 3)
                    .foregroundStyle(.secondary)
            }
        } else {
            Color(nsColor: .quaternaryLabelColor)
        }
    }

    /// The one swatch-edge rule (DS-2): a two-layer hairline — a dark ring at the very
    /// edge over a light ring one point inside — so a swatch's boundary stays visible
    /// against *any* fill in *either* card appearance. A near-black color on a dark card
    /// no longer reads as an unset/empty swatch, and a white color on a light card still
    /// shows an edge. The explicit light+dark pair is deliberate (not a dark-assumed
    /// alpha): whichever one the fill/background swallows, the other contrasts. Applied
    /// identically at every swatch site.
    private func swatchRing(cornerRadius r: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: r)
            .strokeBorder(Color.black.opacity(0.28), lineWidth: 1)
            .overlay(
                RoundedRectangle(cornerRadius: r)
                    .inset(by: 1)
                    .strokeBorder(Color.white.opacity(0.30), lineWidth: 1)
            )
    }

    /// A curated spread of neutrals and hues for one-click picking. The text field
    /// covers everything else — any hex, plus the values a swatch can't express.
    private static let colorPresets: [String] = [
        "#000000", "#1e1e2e", "#282c34", "#3b4252", "#4c566a", "#7f849c", "#abb2bf", "#ffffff",
        "#e06c75", "#d19a66", "#e5c07b", "#98c379", "#56b6c2", "#61afef", "#c678dd", "#ff79c6",
    ]

    private var colorEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                colorFill(draft)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay { swatchRing(cornerRadius: 6) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.option.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(draft.isEmpty ? "no value" : draft)
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                // The native color wheel + eyedropper. Opacity is off so we never emit
                // an `#rrggbbaa` that a non-background color option would reject; the
                // wheel edits the draft live and commits when the popover closes.
                ColorPicker("", selection: colorWellBinding, supportsOpacity: false)
                    .labelsHidden()
                    .help("Pick with the color wheel or eyedropper")
            }
            HStack(spacing: 6) {
                TextField("#1e1e2e, tomato, cell-foreground", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { requestColorApply(draft); showingColorPopover = false }
                Button("Set") { requestColorApply(draft); showingColorPopover = false }
                    .disabled(!canApplyColorDraft)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 5), count: 8), spacing: 5) {
                ForEach(Self.colorPresets, id: \.self) { hex in
                    Button {
                        draft = hex
                        requestColorApply(hex)
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 22, height: 22)
                            .overlay {
                                if isSelectedPreset(hex) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                } else {
                                    swatchRing(cornerRadius: 4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(hex)
                    // A preset swatch is pure color — VoiceOver gets the hex as its name
                    // and the selected one is announced as selected (H3, A11Y-6).
                    .accessibilityLabel("Color \(hex)")
                    .accessibilityAddTraits(isSelectedPreset(hex) ? .isSelected : [])
                }
            }
            Text("Type a hex code, an X11 color name, or cell-foreground / cell-background. Changes save when you close this.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 250)
    }

    /// Two-way bridge to the native picker: read the draft as a Color, and write a
    /// wheel/eyedropper pick back as a `#rrggbb` draft (live preview; commit on close).
    private var colorWellBinding: Binding<Color> {
        Binding(
            get: { Color(hex: draft) ?? Color(nsColor: .textColor) },
            set: { newColor in
                if let hex = newColor.ghosttyHex { draft = hex }
            }
        )
    }

    private func isSelectedPreset(_ hex: String) -> Bool {
        hex.caseInsensitiveCompare(currentValue) == .orderedSame
    }

    /// A blank field or one that matches the saved value is never a valid write.
    private var canApplyColorDraft: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != currentValue
    }

    /// Apply a color value at most once per distinct value in a popover session, so
    /// the wheel's live edits, a preset, "Set", and the on-close commit never stack
    /// into repeated writes (and reloads) of the same value (B6).
    private func requestColorApply(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v != currentValue, v != committedColor else { return }
        committedColor = v
        if v != draft { draft = v }
        apply(v)
    }
}

// MARK: - Numeric editor (U9)

/// The numeric editing control, chosen by the option's `NumericSpec` (B3):
///   - `.slider` → a Slider over [min,max] with a live read-out, committing once on
///     release so the live terminal reloads per gesture, not per pixel
///   - `.field`  → a clamped number field + debounced stepper, with an optional unit
///   - `.size`   → a raw byte field with a human-readable size read-out
///   - no spec   → a plain number field (a stepper appears only when a fractional
///     default earns one; a step-of-1 nudge on an unbounded field is just noise)
///
/// Reads its value from the parent's `draft` (kept in sync with the saved value and
/// snapped back on a failed write), and clamps every write so nothing out of range
/// reaches disk. Continuous input is coalesced — the slider commits on release and
/// the stepper on a short trailing debounce — so a drag or a key-repeat is one write.
private struct NumericOptionEditor: View {
    let option: MergedOption
    @Binding var draft: String
    let savedValue: String
    let placeholder: String
    let apply: (String) -> Void

    /// Live slider position (a Double) distinct from the committed `draft`, so the
    /// knob can move continuously while only the release writes.
    @State private var live: Double = 0
    /// The pending debounced stepper write, cancelled by the next tick so a burst of
    /// increments collapses to a single write.
    @State private var pendingStep: Task<Void, Never>?
    /// Field focus, so a blurred numeric field commits like the free-text fields (B7).
    @FocusState private var fieldFocused: Bool

    private var spec: NumericSpec? { option.option.numericSpec }

    var body: some View {
        Group {
            switch spec?.style {
            case .slider where sliderRange != nil:
                sliderEditor(spec!, range: sliderRange!)
            case .field:
                fieldEditor(spec!)
            case .size:
                sizeEditor
            default:
                plainField
            }
        }
        // Each inner control (slider / field / stepper / size) carries the full shared
        // label (name + default + state) directly; the container keeps the friendly name
        // as a fallback for the whole group.
        .accessibilityLabel(optionControlA11yLabel(option))
        .onChange(of: fieldFocused) { _, focused in
            if !focused { commitOnBlur() }   // commit-on-blur (B7)
        }
        // Don't let a queued debounce write for a row that's been scrolled/filtered away.
        .onDisappear { pendingStep?.cancel() }
    }

    /// Commit whatever's in the field when it loses focus, clamping via the spec for a
    /// bounded field and passing raw for size/plain fields.
    private func commitOnBlur() {
        if let spec, spec.style == .field { commitField(spec) } else { commitUnclamped() }
    }

    // MARK: Slider

    private var sliderRange: ClosedRange<Double>? {
        guard let spec, let lo = spec.min, let hi = spec.max, lo < hi else { return nil }
        return lo...hi
    }

    private func sliderEditor(_ spec: NumericSpec, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Slider(value: $live, in: range, step: spec.step ?? 0.05) { editing in
                    if !editing { commitSlider(spec) }
                }
                .frame(width: 120)
                // Name + default + state on the control itself (not the container, which
                // wouldn't reliably attach), and the friendly value ("85%"), so VoiceOver
                // speaks the same as every other editor rather than a bare track fraction.
                .accessibilityLabel(optionControlA11yLabel(option))
                .accessibilityValue(Text(spec.displayString(for: spec.clamp(live))))
                // Read-out via the spec's display transform: a 0–1 opacity reads "85%",
                // a contrast slider stays a plain number (no scale) (DS-1/U3).
                Text(spec.displayString(for: spec.clamp(live)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            if let minLabel = spec.minLabel, let maxLabel = spec.maxLabel {
                // Endpoint captions resolve an ambiguous direction (which way is solid?),
                // aligned under the 120pt track (DS-1).
                HStack(spacing: 4) {
                    Text(minLabel)
                    Spacer(minLength: 4)
                    Text(maxLabel)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 120)
                .accessibilityHidden(true)
            }
        }
        .onAppear { live = seed(spec) }
        .onChange(of: draft) { _, _ in live = seed(spec) }
    }

    private func commitSlider(_ spec: NumericSpec) {
        let text = numberString(spec.clamp(live), decimals: decimals(for: spec))
        // `draft` holds the saved baseline until commit, so this both de-dupes an
        // unchanged release and avoids a redundant write.
        guard text != draft else { return }
        draft = text
        apply(text)
    }

    /// The slider's starting position: the saved value parsed and clamped into range.
    private func seed(_ spec: NumericSpec) -> Double {
        let raw = Double(draft.trimmingCharacters(in: .whitespaces))
            ?? Double(savedValue.trimmingCharacters(in: .whitespaces))
            ?? spec.min ?? 0
        return spec.clamp(raw)
    }

    // MARK: Field + stepper

    private func fieldEditor(_ spec: NumericSpec) -> some View {
        HStack(spacing: 4) {
            TextField("", text: $draft, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .focused($fieldFocused)
                // Resign on Return so commit-on-blur is the single write path and a
                // following ⌘Z reverts the config write, not the field text (review #2).
                .onSubmit { fieldFocused = false }
                .accessibilityLabel(optionControlA11yLabel(option))
            if let unit = spec.unit {
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            boundedStepper(spec)
        }
    }

    /// A bounded `Stepper(value:in:step:)` so +/- dim at the spec's range ends (CV-6) —
    /// the old callback stepper stayed lit past the boundary. Its binding routes through
    /// the same debounced commit as the field, so a key-repeat burst still collapses to
    /// one write (KTD8 single write path). Falls back to the callback stepper when a
    /// `.field` spec somehow lacks a finite range.
    @ViewBuilder
    private func boundedStepper(_ spec: NumericSpec) -> some View {
        if let lo = spec.min, let hi = spec.max, lo < hi {
            Stepper("", value: stepperBinding(spec), in: lo...hi, step: spec.step ?? 1)
                .labelsHidden()
                .accessibilityLabel(optionControlA11yLabel(option))
        } else {
            Stepper("",
                    onIncrement: { stepField(spec, by: 1) },
                    onDecrement: { stepField(spec, by: -1) })
                .labelsHidden()
                .accessibilityLabel(optionControlA11yLabel(option))
        }
    }

    /// The stepper's value as a Double, read from the current draft (clamped) and written
    /// back through the debounced commit path so it never diverges from the text field.
    private func stepperBinding(_ spec: NumericSpec) -> Binding<Double> {
        Binding(
            get: { seed(spec) },
            set: { newValue in
                let text = numberString(spec.clamp(newValue), decimals: decimals(for: spec))
                draft = text
                scheduleStepCommit(text)
            }
        )
    }

    private func commitField(_ spec: NumericSpec) {
        pendingStep?.cancel()
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed) else {
            draft = savedValue          // non-numeric input reverts to the saved value
            return
        }
        let text = numberString(spec.clamp(value), decimals: decimals(for: spec))
        if text != draft { draft = text }   // reflect the clamp back into the field
        guard text != savedValue else { return }
        apply(text)
    }

    private func stepField(_ spec: NumericSpec, by direction: Double) {
        let base = Double(draft.trimmingCharacters(in: .whitespaces))
            ?? Double(savedValue.trimmingCharacters(in: .whitespaces))
            ?? spec.min ?? 0
        let text = numberString(spec.clamp(base + (spec.step ?? 1) * direction), decimals: decimals(for: spec))
        draft = text
        scheduleStepCommit(text)
    }

    // MARK: Size

    private var sizeEditor: some View {
        let bytes = Double(draft.trimmingCharacters(in: .whitespaces)) ?? 0
        let formatted = bytes > 0 ? NumericSpec.formatBytes(bytes) : ""
        return VStack(alignment: .trailing, spacing: 1) {
            // Primary: the human-readable size — the way a storage limit is actually
            // spoken ("10 MB"), not a wall of digits (CB-5). Hidden from VoiceOver here
            // because it's folded into the editable field's value below (CM-8).
            if !formatted.isEmpty {
                Text(formatted)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
            // The exact byte count stays editable, demoted to a small mono caption.
            TextField("", text: $draft, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(width: 120)
                .focused($fieldFocused)
                .onSubmit { fieldFocused = false }   // resign → commit-on-blur; ⌘Z targets config (review #2)
                .accessibilityLabel(optionControlA11yLabel(option))
                // VoiceOver announces the friendly size, not the raw digits (CM-8).
                .accessibilityValue(Text(formatted.isEmpty ? draft : formatted))
        }
    }

    // MARK: Plain (no spec)

    @ViewBuilder
    private var plainField: some View {
        let inferredStep = NumericSpec.inferredStep(forDefault: option.option.defaultValue)
        HStack(spacing: 4) {
            TextField("", text: $draft, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .focused($fieldFocused)
                .onSubmit { commitUnclamped() }
                .accessibilityLabel(optionControlA11yLabel(option))
            if inferredStep != 1 {
                // A fractional default earns a fine stepper; an integer default drops
                // it, since a whole-number nudge on an unbounded field is noise.
                Stepper("",
                        onIncrement: { stepUnclamped(by: inferredStep) },
                        onDecrement: { stepUnclamped(by: -inferredStep) })
                    .labelsHidden()
                    .accessibilityLabel(optionControlA11yLabel(option))
            }
        }
    }

    private func stepUnclamped(by delta: Double) {
        let base = Double(draft.trimmingCharacters(in: .whitespaces))
            ?? Double(savedValue.trimmingCharacters(in: .whitespaces)) ?? 0
        let value = base + delta
        let text = value.rounded() == value ? String(Int(value)) : numberString(value, decimals: 1)
        draft = text
        scheduleStepCommit(text)
    }

    // MARK: Commit helpers

    private func commitUnclamped() {
        pendingStep?.cancel()
        let text = draft.trimmingCharacters(in: .whitespaces)
        if text != draft { draft = text }
        guard text != savedValue else { return }
        apply(text)
    }

    /// Debounce a stepper burst into one write ~400ms after the last tick — SwiftUI's
    /// Stepper fires per increment with no editing-ended callback, so a real trailing
    /// debounce (not a nonexistent "mouse-up") is what keeps a key-repeat from
    /// spamming validate+write+reload.
    private func scheduleStepCommit(_ text: String) {
        pendingStep?.cancel()
        pendingStep = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, text != savedValue else { return }
            apply(text)
        }
    }

    // MARK: Formatting

    /// Decimal places implied by the step: whole numbers for step ≥ 1, otherwise
    /// enough places to render the step (capped at 3). A non-positive step (a
    /// mis-authored spec) maps to whole numbers rather than trapping: `-log10(0)` is
    /// +∞ and `Int(.infinity)` is a hard crash, and a negative step yields NaN.
    private func decimals(for spec: NumericSpec) -> Int {
        let step = spec.step ?? 1
        guard step > 0 else { return 0 }
        if step >= 1 { return 0 }
        return Swift.min(3, Int(ceil(-log10(step))))
    }

    /// Minimal valid string for a value: an integer when it divides evenly (so
    /// `1.0` writes as `1`, matching the default and reading clean), else a trimmed
    /// fixed-point form (`0.50` → `0.5`).
    private func numberString(_ value: Double, decimals: Int) -> String {
        if value.rounded() == value { return String(Int(value.rounded())) }
        var s = String(format: "%.\(Swift.max(1, decimals))f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

// MARK: - Boolean-ish editor (U10)

/// A toggle-first control for "boolean impostor" options — those that accept
/// `true`/`false` alongside richer values (B4). The switch handles the on/off axis
/// the way a newcomer expects (no more editing a text box that reads `false`); a
/// trailing menu exposes the extra states (`always`, `left`, `osc8`, glass styles…)
/// with friendly labels for anyone who needs them.
///
/// Value round-trip (R8): turning **On** restores the last non-`false` value the user
/// had — client-cached across the toggle — or `true` if none; turning **Off** writes
/// `false` while *preserving* that cache, so a custom value (a blur radius, a `left`
/// Option mapping) survives an off→on cycle instead of collapsing to a bare `true`.
private struct BooleanishEditor: View {
    let option: MergedOption
    let savedValue: String
    let apply: (String) -> Void
    /// Return the option to its unset/default state (used by the Default choice when
    /// the effective boolean is undocumented, so "Default" is distinct from "Off").
    let reset: () -> Void

    /// The last "on" (non-`false`) value seen, so Off→On restores it rather than
    /// snapping to a bare `true`. Seeded from the saved value and kept in sync with it.
    @State private var lastOnValue: String?

    /// Default / On / Off, for options whose effective boolean can't be resolved (R1).
    private enum TriState: Hashable { case unset, on, off }

    var body: some View {
        Group {
            if option.booleanControlStyle == .defaultOnOffChoice {
                defaultOnOffPicker
            } else {
                switchWithExtras
            }
        }
    }

    /// An explicit three-way choice for an unset option with no documented default,
    /// so the control never renders a bare Off it can't justify (R1, U2, AE-adjacent).
    private var defaultOnOffPicker: some View {
        Picker("", selection: triStateBinding) {
            Text("Default").tag(TriState.unset)
            Text("On").tag(TriState.on)
            Text("Off").tag(TriState.off)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityLabel(optionControlA11yLabel(option))
    }

    private var triStateBinding: Binding<TriState> {
        Binding(
            get: {
                if !option.isSet { return .unset }
                return isOn(savedValue) ? .on : .off
            },
            set: { choice in
                switch choice {
                case .unset: reset()
                case .on: apply(lastOnValue ?? "true")
                case .off: apply("false")
                }
            }
        )
    }

    private var switchWithExtras: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: onBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(optionControlA11yLabel(option))
            // Exactly one extra state reads as a labeled checkbox refining "on" — no
            // mystery single-item menu (CV-5). It's a modifier of the on-state, so it
            // appears only while the switch is on. Two or more extras keep the menu.
            if isOn(savedValue), let single = singleExtra {
                Toggle(isOn: extraBinding(single)) {
                    Text(single.label).font(.callout)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            } else if extraChoices.count >= 2 {
                extrasMenu
            }
        }
        .onAppear { if isOn(savedValue) { lastOnValue = savedValue } }
        .onChange(of: savedValue) { _, newValue in
            if isOn(newValue) { lastOnValue = newValue }
        }
    }

    /// On unless the value is exactly `false` (or empty/unset) — any richer value
    /// (`always`, `left`, a blur radius, a glass style) reads as enabled.
    private func isOn(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        return !(v.isEmpty || v == "false")
    }

    private var onBinding: Binding<Bool> {
        Binding(
            get: { isOn(savedValue) },
            set: { turnOn in
                if turnOn {
                    apply(lastOnValue ?? "true")
                } else {
                    if isOn(savedValue) { lastOnValue = savedValue } // preserve for re-enable
                    apply("false")
                }
            }
        )
    }

    /// The documented values beyond the plain true/false axis — the "extra states"
    /// the trailing checkbox/menu offers (with friendly labels, raw tags).
    private var extraChoices: [EnumChoice] {
        option.enumChoices(current: savedValue)
            .filter { $0.value != "true" && $0.value != "false" && !$0.value.isEmpty }
    }

    /// The sole extra state when there's exactly one, rendered as a checkbox (CV-5).
    private var singleExtra: EnumChoice? {
        extraChoices.count == 1 ? extraChoices.first : nil
    }

    /// Checkbox binding for the single extra: checked applies the extra value ("always"),
    /// unchecked falls back to plain "true" (still on). Caching in `onChange` keeps the
    /// off→on round-trip (B4).
    private func extraBinding(_ choice: EnumChoice) -> Binding<Bool> {
        Binding(
            get: { savedValue.trimmingCharacters(in: .whitespaces) == choice.value },
            set: { checked in apply(checked ? choice.value : "true") }
        )
    }

    private var extrasMenu: some View {
        Menu {
            ForEach(extraChoices) { choice in
                Button {
                    lastOnValue = choice.value
                    apply(choice.value)
                } label: {
                    if choice.value == savedValue {
                        Label(choice.label, systemImage: "checkmark")
                    } else {
                        Text(choice.label)
                    }
                }
            }
        } label: {
            Text(activeExtraLabel).font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More options")
        .accessibilityLabel(Text("\(option.option.displayTitle) — more options"))
    }

    /// The active extra's label when one is selected, else a neutral affordance.
    private var activeExtraLabel: String {
        extraChoices.first { $0.value == savedValue }?.label ?? "More…"
    }
}

// MARK: - Font family picker

/// A font selector for `font-family` (and its bold/italic variants). Ghostty treats
/// these as repeatable — the first value is the primary face and any others are
/// fallbacks for glyphs it lacks (the common "add a Nerd Font for icons" setup) —
/// so this is a multi-select over the fonts Ghostty can actually use (`+list-fonts`,
/// with the system font list as a fallback). Each write reuses the model's safe
/// apply path, and an empty selection unsets the key back to Ghostty's built-in font.
private struct FontFamilyEditor: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption
    @State private var showingPicker = false
    @State private var search = ""

    var body: some View {
        Button { showingPicker.toggle() } label: { label }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Choose a font family")
            .disabled(isApplyingThis)
            // Prefetch the font list when the row appears so the picker opens ready,
            // rather than paying `+list-fonts` on first click. Cached after the first
            // load, so the other font-family rows don't reload it.
            .task { await model.loadFontsIfNeeded() }
            .popover(isPresented: $showingPicker, arrowEdge: .bottom) { picker }
            // Close-and-act: clicking the sidebar (or a control) right after the picker
            // opens shouldn't be eaten by the popover's dismiss (U11/MO-1).
            .passthroughPopoverDismiss(isPresented: $showingPicker)
    }

    // MARK: Button label

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: "textformat")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(summary)
                .font(primaryPreviewFont)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
    }

    /// The live option from the model, not the captured `option` prop. A `.popover`
    /// holds onto the view value it was presented with, so reading `option` directly
    /// leaves the picker's checkmarks/labels stale after an in-place apply (the write
    /// lands and the row's button updates, but the open popover keeps the old values).
    /// Reading the observable model re-renders the popover on every write.
    private var liveOption: MergedOption {
        model.browser?.merged.option(named: option.option.name) ?? option
    }

    /// The current families, or empty when the option is unset (Ghostty's built-in).
    private var selected: [String] { liveOption.isSet ? liveOption.userValues : [] }

    private var summary: String {
        if let primary = selected.first {
            let name = displayName(primary)
            return selected.count > 1 ? "\(name)  +\(selected.count - 1)" : name
        }
        let def = option.option.defaultValue
        return def.isEmpty ? "Default font" : displayName(def)
    }

    /// Preview the chosen primary face in its own typeface (falls back to the system
    /// font when the name doesn't resolve), like a real font menu.
    private var primaryPreviewFont: Font {
        // `relativeTo:` so the face preview scales with the user's text-size setting
        // instead of being pinned at 12pt (H3, Dynamic Type).
        if let primary = selected.first { return .custom(displayName(primary), size: 12, relativeTo: .callout) }
        return .system(.callout)
    }

    // MARK: Popover

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Friendly title over the raw key as a mono caption — matching the info
            // popover's header pattern, so the picker names "Font", not "font-family" (CB-3).
            VStack(alignment: .leading, spacing: 1) {
                Text(option.option.displayTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(option.option.name)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TextField("Search fonts", text: $search)
                .textFieldStyle(.roundedBorder)

            if !searchTrimmed.isEmpty && !searchMatchesKnown {
                Button {
                    toggle(searchTrimmed)
                    search = ""
                } label: {
                    Label("Use “\(searchTrimmed)”", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if pickerRows.isEmpty {
                        Text(fonts.isEmpty ? "Loading fonts…" : "No fonts match “\(searchTrimmed)”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        // One ForEach with section-scoped ids (not two ForEaches over a
                        // shared \.self key): when a font moves between Selected and All
                        // fonts its identity changes, so LazyVStack rebuilds it fresh
                        // instead of reusing a cached row with a now-wrong checkmark.
                        ForEach(pickerRows) { row in
                            switch row {
                            case .header(let title):
                                if title == "All fonts" { Divider().padding(.vertical, 5) }
                                sectionHeader(title)
                            case .font(_, let value):
                                FontRow(
                                    name: displayName(value),
                                    selectionLabel: selectionLabel(for: value),
                                    isSelected: isSelected(value),
                                    onTap: { toggle(value) }
                                )
                            }
                        }
                    }
                }
            }
            .frame(height: 300)

            Divider()
            HStack(alignment: .top, spacing: 8) {
                Text("The first font is the primary face; add more as fallbacks for glyphs it’s missing (e.g. a Nerd Font for icons).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if liveOption.isSet {
                    Button("Reset") { apply([]) }
                        .controlSize(.small)
                        .help("Clear these fonts and use Ghostty’s built-in default")
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
            .padding(.bottom, 3)
    }

    /// One entry in the picker list — a section header or a font, each with a stable,
    /// section-scoped identity so `ForEach`/`LazyVStack` never reuse a row across
    /// sections (which left a moved font showing a stale checkmark).
    private enum PickerRow: Identifiable {
        case header(String)
        case font(section: String, value: String)

        var id: String {
            switch self {
            case .header(let title): return "header:\(title)"
            case .font(let section, let value): return "\(section):\(value)"
            }
        }
    }

    private var pickerRows: [PickerRow] {
        var rows: [PickerRow] = []
        let sel = filteredSelected
        let rest = filteredRest
        if !sel.isEmpty {
            rows.append(.header("Selected"))
            rows.append(contentsOf: sel.map { .font(section: "selected", value: $0) })
        }
        if !rest.isEmpty {
            if !sel.isEmpty { rows.append(.header("All fonts")) }
            rows.append(contentsOf: rest.map { .font(section: "all", value: $0) })
        }
        return rows
    }

    private func isSelected(_ value: String) -> Bool {
        selected.contains { normalized($0) == normalized(value) }
    }

    /// "Primary" for the first family, "Fallback" for the rest, or nil when unselected.
    private func selectionLabel(for value: String) -> String? {
        guard let idx = selected.firstIndex(where: { normalized($0) == normalized(value) }) else { return nil }
        return idx == 0 ? "Primary" : "Fallback"
    }

    // MARK: Font list

    /// Ghostty's own discovery (`+list-fonts`) is the source of truth — it includes
    /// faces Ghostty ships that aren't installed system-wide — with the AppKit family
    /// list as a fallback so the picker is never empty while `+list-fonts` is loading
    /// or if it returns nothing.
    private var fonts: [String] {
        model.fonts.isEmpty ? NSFontManager.shared.availableFontFamilies : model.fonts
    }

    private var searchTrimmed: String { search.trimmingCharacters(in: .whitespaces) }

    /// True when the search text already names a known or selected font, so the
    /// "Use “…”" free-text affordance doesn't shadow an existing entry.
    private var searchMatchesKnown: Bool {
        guard !searchTrimmed.isEmpty else { return false }
        return (fonts + selected).contains { normalized($0) == normalized(searchTrimmed) }
    }

    private var filteredSelected: [String] { filterBySearch(selected) }

    private var filteredRest: [String] {
        let selectedNames = Set(selected.map(normalized))
        return filterBySearch(fonts.filter { !selectedNames.contains(normalized($0)) })
    }

    private func filterBySearch(_ list: [String]) -> [String] {
        guard !searchTrimmed.isEmpty else { return list }
        let needle = normalized(searchTrimmed)
        return list.filter { normalized($0).contains(needle) }
    }

    private var isApplyingThis: Bool {
        model.applyingOptionName == option.option.name && model.applyState == .applying
    }

    /// Ghostty accepts quoted font names (`font-family = "MesloLGS NF"`); the quotes
    /// are just a quoting mechanism, so strip one surrounding pair for display and
    /// for the custom-font preview (a quoted name won't resolve). Uses the shared
    /// helper so the quote-stripping rule is defined once.
    private func displayName(_ font: String) -> String { font.strippingConfigQuotes }

    /// The comparison key for a font: de-quoted and case-folded, so a quoted saved
    /// value (`"MesloLGS NF"`) matches the unquoted name from `+list-fonts`
    /// (`MesloLGS NF`) and the same font never appears in both sections — or gets
    /// appended a second time.
    private func normalized(_ font: String) -> String { displayName(font).lowercased() }

    // MARK: Mutations

    /// Add the font if it isn't selected, or remove it if it is — preserving the
    /// order of the remaining families so the primary/fallback ordering is stable.
    private func toggle(_ font: String) {
        var values = selected
        if let idx = values.firstIndex(where: { normalized($0) == normalized(font) }) {
            values.remove(at: idx)
        } else {
            values.append(font)
        }
        apply(values)
    }

    /// Route through the model's safe apply path. An empty list unsets the key
    /// (the writer removes every `font-family` line), reverting to the built-in font.
    private func apply(_ values: [String]) {
        Task { await model.applyEdit(option: option, values: values) }
    }
}

/// One row in the font picker. A value-driven `View` (not a helper function) so its
/// checkmark and label follow `isSelected`/`selectionLabel` when the selection
/// changes — the row updates in place instead of holding a stale rendering.
private struct FontRow: View {
    let name: String
    let selectionLabel: String?
    let isSelected: Bool
    let onTap: () -> Void

    /// A fixed terminal-representative sample: mixed-case letterforms, digits, the
    /// programming ligature triggers (`->`, `=>`, `!=`), and a check glyph — so
    /// monospacing, ligatures, and Nerd-Font coverage are visible in the row's own
    /// face rather than guessed from the name alone (CV-12).
    private static let sample = "AaBbGg 0123 -> => != ✓"

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        // Each name rendered in its own face, so the list reads like a
                        // font menu; unresolvable names fall back to the system font.
                        // `relativeTo:` lets the list scale with Dynamic Type (H3).
                        .font(.custom(name, size: 14, relativeTo: .body))
                        .lineLimit(1)
                    Text(Self.sample)
                        .font(.custom(name, size: 12, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // Decorative — the row's a11y label already names the font.
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                if let selectionLabel {
                    Text(selectionLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
        // The font name renders in its own face (a visual cue lost to VoiceOver), so
        // name it and announce the current pick as selected (H3, A11Y-6).
        .accessibilityLabel(selectionLabel.map { "\(name), \($0)" } ?? name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Palette editor (U14)

/// A 16-swatch grid for the `palette` repeatable option — each ANSI slot picked with
/// the native color well, rebuilding the `index=#hex` value list through the safe
/// repeatable write path (B8, R5). Unset slots are seeded from the current theme's
/// palette so the grid shows the colors actually in effect; only slots the user edits
/// are written, leaving the rest to follow the theme. When the theme's colors haven't
/// loaded yet the untouched slots simply render blank with a hint — a graceful
/// fallback, since `themeColors` is populated lazily.
private struct PaletteEditor: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption
    @State private var showing = false
    /// The user's slots being edited, seeded from the saved value when the popover
    /// opens. Edits mutate this locally (live preview) and are committed through a
    /// trailing debounce — the native ColorPicker fires its setter continuously while
    /// the wheel drags, so committing per tick would storm the writer with a
    /// validate+write+reload each and race into stale-on-disk failures.
    @State private var working: [Int: String] = [:]
    @State private var isEditing = false
    @State private var pendingCommit: Task<Void, Never>?

    private static let ansiNames = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
        "Bright Black", "Bright Red", "Bright Green", "Bright Yellow",
        "Bright Blue", "Bright Magenta", "Bright Cyan", "Bright White",
    ]

    /// The live `palette` option, so the grid re-renders after an in-place write
    /// (the captured `option` prop goes stale inside a popover, like FontFamilyEditor).
    private var liveOption: MergedOption {
        model.browser?.merged.option(named: "palette") ?? option
    }

    private var userSlots: [Int: String] { GhosttyPalette.parse(liveOption.userValues) }
    private var themeSlots: [Int: String] { model.currentThemePalette() }

    /// The color in force for a slot: the local edit while the popover is open, else
    /// the user's saved value, else the theme's.
    private func color(at index: Int) -> String? {
        (isEditing ? working[index] : userSlots[index]) ?? themeSlots[index]
    }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                miniPreview
                Text(userSlots.isEmpty ? "Edit…" : "\(userSlots.count) set")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Edit the 16 ANSI terminal colors")
        .popover(isPresented: $showing, arrowEdge: .bottom) { grid }
        // Seed unset slots from the current theme; harmless (cached) if already loaded.
        .task { await model.loadCurrentThemeColorsIfNeeded() }
        // Seed the working copy on open; flush any pending edit on close.
        .onChange(of: showing) { _, open in
            if open {
                working = userSlots
                isEditing = true
            } else {
                pendingCommit?.cancel()
                flushCommit()
                isEditing = false
            }
        }
    }

    private var miniPreview: some View {
        HStack(spacing: 1) {
            ForEach(0..<8, id: \.self) { index in
                Rectangle()
                    .fill(Color(hex: color(at: index)) ?? Color(nsColor: .quaternaryLabelColor))
                    .frame(width: 5, height: 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Palette").font(.callout.weight(.semibold))
            if userSlots.isEmpty && themeSlots.isEmpty {
                Text("Open Themes once to load this theme's colors, or set slots directly below.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 8) {
                ForEach(0..<GhosttyPalette.slotCount, id: \.self) { index in
                    slotRow(index)
                }
            }
            Divider()
            HStack {
                Text("Unset slots follow the current theme.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !working.isEmpty {
                    Button("Reset all") {
                        pendingCommit?.cancel()
                        working = [:]
                        applyNow([])
                    }
                    .controlSize(.small)
                    .help("Clear every custom slot and follow the theme")
                }
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private func slotRow(_ index: Int) -> some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: binding(for: index), supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel(Text("ANSI \(index), \(Self.ansiNames[index])"))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(index)  \(Self.ansiNames[index])").font(.caption).lineLimit(1)
                Text(color(at: index) ?? "—")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// A native-picker binding for one slot: read the color in force, and on pick
    /// stage the change in the local working copy (live preview) with a debounced
    /// commit — never a write per wheel tick.
    private func binding(for index: Int) -> Binding<Color> {
        Binding(
            get: { Color(hex: color(at: index)) ?? Color(nsColor: .quaternaryLabelColor) },
            set: { newColor in
                guard let hex = newColor.ghosttyHex else { return }
                // Ignore a no-op callback (e.g. the panel echoing the current color on
                // open) so an unset slot isn't silently pinned to its placeholder gray.
                guard hex.caseInsensitiveCompare(color(at: index) ?? "") != .orderedSame else { return }
                working[index] = hex
                scheduleCommit()
            }
        )
    }

    /// Coalesce a burst of wheel ticks into a single write ~350ms after the last one.
    private func scheduleCommit() {
        pendingCommit?.cancel()
        pendingCommit = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            flushCommit()
        }
    }

    /// Write the working copy through the safe repeatable path, but only when it
    /// differs from what's already saved.
    private func flushCommit() {
        let values = GhosttyPalette.valueList(working)
        guard values != liveOption.userValues else { return }
        applyNow(values)
    }

    private func applyNow(_ values: [String]) {
        Task { await model.applyEdit(option: liveOption, values: values) }
    }
}

// MARK: - Repeatable list editor (U14)

/// An add/remove list for repeatable text options (`env`, `font-feature`) — the
/// proven "Edit…" popover pattern over a list of value rows, each write routed
/// through the safe repeatable path (B8).
private struct ListValueEditor: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption
    /// A fixed button label — e.g. font-feature's "Customize…" disclosure — instead of
    /// the default "Add…"/"N set" count (U8).
    var customLabel: String? = nil
    @State private var showing = false
    @State private var newEntry = ""

    private var liveOption: MergedOption {
        model.browser?.merged.option(named: option.option.name) ?? option
    }
    private var entries: [String] { liveOption.isSet ? liveOption.userValues : [] }

    var body: some View {
        Button { showing.toggle() } label: {
            Text(customLabel ?? (entries.isEmpty ? "Add…" : "\(entries.count) set"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Edit \(option.option.displayTitle)")
        .popover(isPresented: $showing, arrowEdge: .bottom) { editor }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(option.option.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
            if entries.isEmpty {
                Text("No entries yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: 6) {
                        Text(entry)
                            .font(.callout.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button { remove(at: index) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove")
                        .accessibilityLabel("Remove \(entry)")
                    }
                }
            }
            Divider()
            HStack(spacing: 6) {
                TextField(placeholder, text: $newEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Add") { add() }
                    .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private var placeholder: String {
        if option.option.name == "env" { return "KEY=VALUE" }
        return LabelCatalog.fieldPlaceholder(
            name: option.option.name,
            title: option.option.displayTitle,
            documentation: option.option.documentation,
            defaultValue: option.option.defaultValue
        )
    }

    private func add() {
        let entry = newEntry.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return }
        apply(entries + [entry])
        newEntry = ""
    }

    private func remove(at index: Int) {
        var next = entries
        guard next.indices.contains(index) else { return }
        next.remove(at: index)
        apply(next)
    }

    private func apply(_ values: [String]) {
        Task { await model.applyEdit(option: liveOption, values: values) }
    }
}

// MARK: - Font-feature (Ligatures) editor

/// `font-feature` (titled "Ligatures") rendered toggle-first (CV-9): the common case is
/// "ligatures on or off", so a switch drives that — On strips Ghostty's `-calt, -liga,
/// -dlig` disable set, Off writes it — over the kit `FontFeatures` tag arithmetic that
/// preserves any user-added stylistic tags. The full per-tag list stays reachable behind
/// a secondary "Customize…" disclosure for `ss01`-style sets.
private struct FontFeatureEditor: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption

    /// Read the value in force from the live merged model, so the toggle reflects an
    /// external edit or a just-applied write.
    private var liveOption: MergedOption {
        model.browser?.merged.option(named: option.option.name) ?? option
    }
    private var values: [String] { liveOption.isSet ? liveOption.userValues : [] }

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: ligatureBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(optionControlA11yLabel(option))
            ListValueEditor(option: option, customLabel: "Customize…")
        }
    }

    private var ligatureBinding: Binding<Bool> {
        Binding(
            get: { FontFeatures.ligaturesEnabled(values) },
            set: { on in
                let next = on ? FontFeatures.enablingLigatures(values)
                              : FontFeatures.disablingLigatures(values)
                Task { await model.applyEdit(option: liveOption, values: next) }
            }
        )
    }
}

// MARK: - Info popover

/// The popover behind a row's info button: the fuller documentation plus the
/// metadata and read-only actions that used to live in the detail pane (default,
/// where it's defined, Copy snippet, Reveal in editor). Scrollable and
/// width-constrained so long docs stay readable; text is selectable so users can
/// copy examples out.
private struct OptionInfoPopover: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Divider()
            // Only the prose scrolls; the decision facts (Your value / Default / where
            // it's defined / Reset) pin as a footer below, so they never hide behind long
            // documentation (CM-4, Xcode Quick Help pattern).
            ScrollView {
                documentation
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                metadata
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(width: 380)
        .frame(maxHeight: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(option.option.displayTitle)
                .font(.headline)
                .textSelection(.enabled)
            // The raw config key, demoted beneath the friendly title but selectable
            // so a power user can copy the exact key to paste into a config (R8).
            Text(option.option.name)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Pill(text: option.option.category, systemImage: "folder")
                // The friendly type name ("Choice", "On/off"), and no chip at all for an
                // untyped option — a bare "unknown" told the reader nothing (CM-10/CV-4).
                if let typeName = option.option.valueType.displayName {
                    Pill(text: typeName, systemImage: "tag")
                }
                if option.option.isRepeatable {
                    Pill(text: "repeatable", systemImage: "plus.square.on.square")
                }
                stateBadge
            }
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch option.state {
        case .setNonDefault:
            // DS-4: render the state's own display name ("Customized"), not a lowercase literal.
            Pill(text: option.state.displayName, systemImage: "pencil", tint: .accentColor)
        case .setToDefault:
            Pill(text: "at default", systemImage: "equal", tint: .secondary)
        case .unset:
            Pill(text: "not using yet", systemImage: "sparkles", tint: .orange)
        }
    }

    private var documentation: some View {
        Group {
            if hasDoc {
                let blocks = DocFormatter.format(option.option.documentation)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        switch block {
                        case .paragraph(let text):
                            Text(Self.styled(text, boldFirstSentence: index == 0))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .bullet(let text):
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(Self.styled(text, boldFirstSentence: false))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .foregroundStyle(.primary)
            } else {
                Text("No documentation available.").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Style one reflowed doc block (`DocFormatter` already joined hard wraps and lifted
    /// bullets): render `backtick` spans monospaced and — for the summary paragraph only
    /// — bold the first sentence so it stands out (H3/GAP-8/U9). Deliberately NOT full
    /// Markdown; only the two cues Ghostty docs actually use.
    static func styled(_ text: String, boldFirstSentence: Bool) -> AttributedString {
        var result = AttributedString()
        // Odd-indexed segments (between backticks) are code spans.
        for (index, segment) in text.components(separatedBy: "`").enumerated() {
            var piece = AttributedString(segment)
            if !index.isMultiple(of: 2) { piece.font = .callout.monospaced() }
            result.append(piece)
        }
        if boldFirstSentence, let dotSpace = result.range(of: ". ") {
            result[result.startIndex..<dotSpace.upperBound].font = .callout.bold()
        }
        return result
    }

    /// Open a config file in an editor, falling back to TextEdit when the file has no
    /// extension (the bare `config` has no default handler, so `open` would fail/prompt).
    static func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if NSWorkspace.shared.open(url) { return }
        // Extensionless `config` has no default handler — fall back to TextEdit, located
        // by bundle id (robust to relocation) rather than a hardcoded /System path.
        if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            if option.isSet {
                LabeledRow("Your value") {
                    metadataValue(option.userValues.map(displayValue).joined(separator: "\n"))
                }
            }
            LabeledRow("Default") {
                metadataValue(option.valuePresentation.origin == .unresolvedDefault
                              ? "Not documented"
                              : displayValue(option.option.presentation.effectiveDefault ?? option.option.defaultValue),
                              secondary: true)
            }
            if let source = option.sources.first {
                LabeledRow("Defined in") {
                    Text("\((source.file as NSString).lastPathComponent):\(source.line)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A metadata value's display form: enum / boolean-ish values pass through the label
    /// humanizer ("bar" → "Bar", "true" → "On") so a raw token never shows here (KTD3);
    /// every other value (hex, path, number) stays its exact stripped self.
    private func displayValue(_ raw: String) -> String {
        let stripped = raw.strippingConfigQuotes
        guard isEnumLike else { return stripped }
        return EnumValueLabels.bundled.label(option: option.option.name, value: stripped)
    }

    private var isEnumLike: Bool {
        option.option.valueType == .enumeration || option.option.isBooleanish
    }

    /// Render a metadata value: mono for raw tokens (hex/paths/numbers), regular text for
    /// a humanized enum label — a word reads oddly in monospace.
    private func metadataValue(_ text: String, secondary: Bool = false) -> some View {
        Text(text)
            .font(isEnumLike ? .callout : .callout.monospaced())
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .textSelection(.enabled)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                copySnippet()
            } label: {
                Label(copied ? "Copied" : "Copy snippet", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            if let source = option.sources.first {
                // Split the old single "Reveal in editor" (H3/GAP-8): Reveal in Finder
                // always works; Open in editor opens the file, falling back to TextEdit
                // for the extensionless `config` (which has no default handler app).
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.file)])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Button {
                    Self.openInEditor(source.file)
                } label: {
                    Label("Open in editor", systemImage: "arrow.up.forward.app")
                }
            }
            // Only offer a reset when there's a user value to clear (B5). Writing an
            // empty value list is the existing "unset" path — the writer removes the
            // option's line(s) — so no kit change is needed.
            if option.isSet {
                Button(role: .destructive) {
                    Task { await model.applyEdit(option: option, values: []) }
                } label: {
                    Label("Reset to default", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var hasDoc: Bool { !option.option.documentation.isEmpty }

    private func copySnippet() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.snippet(for: option), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

// MARK: - Small reusable bits

extension String {
    /// Strip one surrounding pair of double quotes — Ghostty's quoting for values
    /// with spaces (`font-family = "MesloLGS NF"`). The quotes are a config-syntax
    /// artifact, not part of the value the user thinks in, so display strips them
    /// (CONTENT-16). Trims surrounding whitespace first. Promoted from
    /// `FontFamilyEditor.displayName` so every place a value renders as text can reuse it.
    var strippingConfigQuotes: String {
        let trimmed = trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}

extension Color {
    /// `#rrggbb` for this color in sRGB, for writing a wheel/eyedropper pick back as
    /// a Ghostty hex value (B6). Nil if it can't be represented in RGB.
    var ghosttyHex: String? { NSColor(self).ghosttyHex }
}

extension NSColor {
    /// `#rrggbb` in sRGB (opacity dropped — Ghostty color options take an RGB triple),
    /// or nil when the color can't convert to sRGB.
    var ghosttyHex: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}
