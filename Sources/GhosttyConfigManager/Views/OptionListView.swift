import SwiftUI
import AppKit
import GhosttyConfigKit

/// The main column: a searchable list of options for the current selection.
/// Each row edits its option inline (U7), so there is no separate detail pane —
/// the value control lives on the row and the fuller docs/metadata/actions live
/// in a popover behind the row's info button.
struct OptionListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.browser == nil {
                ProgressView("Loading catalog…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleOptions.isEmpty {
                emptyState
            } else if model.showsSplitSections {
                // A browsed category splits into a Common section and a collapsible
                // Advanced section (B1); the subview owns the per-category
                // expand/collapse state, keyed so each category remembers its own.
                CategoryOptionList(category: categoryName)
            } else {
                // Search and the Customized surface show one flat, ranked list —
                // the Common/Advanced split is a browse-only affordance.
                List(model.visibleOptions, selection: $model.selectedOptionName) { option in
                    OptionRow(option: option)
                        .tag(option.option.name)
                }
            }
        }
        .searchable(text: $model.query, placement: .toolbar,
                    prompt: "Search options or describe a behavior")
        .navigationTitle(title)
        .navigationSplitViewColumnWidth(min: 360, ideal: 460)
        // Leaving a surface clears any lingering per-row apply feedback so the
        // next surface doesn't show a stale "Saved" on some unrelated row.
        .onChange(of: model.selection) { _, _ in model.resetApplyState() }
    }

    private var title: String {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty { return "Search" }
        switch model.selection {
        case .category(let c): return c
        case .customized: return "Customized"
        case .problems: return "Problems"
        case .themes: return "Themes"
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
            ContentUnavailableView("Nothing customized yet",
                                   systemImage: "pencil",
                                   description: Text("Options you change will show up here."))
        } else {
            ContentUnavailableView("No options",
                                   systemImage: "tray",
                                   description: Text("Nothing to show for this selection."))
        }
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
    let category: String
    @AppStorage private var advancedExpanded: Bool

    init(category: String) {
        self.category = category
        _advancedExpanded = AppStorage(wrappedValue: false, "advancedExpanded.\(category)")
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedOptionName) {
            let common = model.commonOptions
            let advanced = model.advancedOptions
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
                    Section(isExpanded: $advancedExpanded) {
                        rows(advanced)
                    } header: {
                        Text("Advanced (\(advanced.count))")
                    }
                }
            }
        }
    }

    private func rows(_ options: [MergedOption]) -> some View {
        ForEach(options) { option in
            OptionRow(option: option)
                .tag(option.option.name)
        }
    }
}

/// One row in the option list: a state dot, the option's name and default, the
/// inline editing control, and an info button that reveals the fuller docs,
/// metadata, and actions in a popover. Apply feedback (saving/saved/error) is
/// shown inline beneath the row while this option is the one being written.
struct OptionRow: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption
    @State private var showingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                    .help(stateHelp)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.option.displayTitle)
                        .font(.body)
                        // The raw key is demoted to the popover (and search, R8); a
                        // hover tooltip keeps it a keystroke away for power users.
                        .help(option.option.name)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(subtitle)
                    }
                }
                Spacer(minLength: 12)
                editor
                infoButton
            }
            feedback
        }
        .padding(.vertical, 2)
    }

    /// Repeatable keys (keybind, palette, …) can't be edited from a single inline
    /// control, so those rows show no editor — their values are summarised in the
    /// subtitle and edited via "Reveal in editor" in the info popover.
    ///
    /// `font-family` and its bold/italic variants are the exception: they're
    /// repeatable (primary + fallbacks, e.g. a Nerd Font for icons), but a font is
    /// something you pick from a list, so they get a dedicated font picker instead.
    @ViewBuilder
    private var editor: some View {
        if option.option.name.hasPrefix("font-family") {
            FontFamilyEditor(option: option)
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(docHelp)
        .accessibilityLabel("Info for \(option.option.name)")
        .popover(isPresented: $showingInfo, arrowEdge: .trailing) {
            OptionInfoPopover(option: option)
        }
    }

    /// Per-row apply status, shown only while this option is the one being written
    /// (`applyingOptionName`), so a single global apply state never decorates the
    /// wrong row.
    @ViewBuilder
    private var feedback: some View {
        if model.applyingOptionName == option.option.name {
            switch model.applyState {
            case .idle:
                EmptyView()
            case .applying:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, 15)
            case .succeeded(let notice, let gitTracked, let reload):
                VStack(alignment: .leading, spacing: 2) {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                    if let notice { Text(notice).font(.caption2).foregroundStyle(.secondary) }
                    if let reloadMessage = reload.message {
                        Text(reloadMessage).font(.caption2).foregroundStyle(.secondary)
                    }
                    if gitTracked {
                        Text("This file is git-tracked — commit it in your dotfiles repo.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if model.canUndo {
                        Button("Undo") { Task { await model.undoLastApply() } }
                            .buttonStyle(.link).font(.caption2)
                    }
                }
                .padding(.leading, 15)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 15)
            }
        }
    }

    private var docHelp: String {
        let doc = option.option.documentation
        return doc.isEmpty ? "No documentation available." : doc
    }

    /// A plain-language one-line description of what the option does (A1). The
    /// default/value context that used to live here ("default: X" / "no default" /
    /// "default: default") now lives in the info popover, so the row reads as
    /// name + purpose. Empty when the catalog has no summary, and the line is then
    /// hidden rather than showing filler.
    private var subtitle: String {
        option.option.shortSummary
    }

    private var stateColor: Color {
        switch option.state {
        case .setNonDefault: return .accentColor
        case .setToDefault: return .secondary
        case .unset: return Color.secondary.opacity(0.25)
        }
    }

    private var stateHelp: String {
        switch option.state {
        case .setNonDefault: return "Set to a non-default value"
        case .setToDefault: return "Set to the default value"
        case .unset: return "Not set — using the default"
        }
    }
}

// MARK: - Inline editor (U7)

/// A type-appropriate editing control rendered directly on the row. Discrete
/// controls (toggle, dropdown, stepper) apply immediately on change; free-text
/// commits on Return. Every write is validated against the live binary by the
/// model, so on failure the control snaps back to the value that's actually saved.
private struct InlineOptionEditor: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption
    @State private var draft: String = ""
    /// Drives the color-editing popover anchored to the row's swatch.
    @State private var showingColorPopover = false

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
            BooleanishEditor(option: option, savedValue: currentValue, apply: { apply($0) })
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
                .accessibilityLabel(Text(option.option.displayTitle))
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
            .fixedSize()
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
                .popover(isPresented: $showingColorPopover, arrowEdge: .bottom) {
                    colorEditor
                }
                // Seed the draft from the saved value each time the popover opens,
                // so it never shows a stale (or first-open empty) value and any
                // uncommitted edit from a previous open is discarded.
                .onChange(of: showingColorPopover) { _, isOpen in
                    if isOpen { draft = currentValue }
                }
        default:
            TextField(fieldPlaceholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onSubmit { commit() }
        }
    }

    private var currentValue: String {
        option.isSet ? (option.userValues.first ?? "") : option.option.defaultValue
    }

    /// A hint for an empty free-text field. For untyped/text options, prefer a
    /// concrete example mined from the docs (CONTROLS-17) so the field hints at the
    /// *shape* of a valid value; otherwise fall back to the option's default value,
    /// then a neutral "value". Replaces the old generic "value" placeholder (CONTROLS-15).
    private var fieldPlaceholder: String {
        if option.option.valueType == .unknown || option.option.valueType == .string {
            let example = LabelCatalog.exampleValue(from: option.option.documentation, excluding: option.option.name)
            if !example.isEmpty { return example }
        }
        let def = option.option.defaultValue.strippingConfigQuotes
        return def.isEmpty ? "value" : def
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

    /// The row's color chip: the saved color, or a neutral fill for values a swatch
    /// can't render (a named color or `cell-foreground` / `cell-background`).
    private var swatch: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(hex: currentValue) ?? Color(nsColor: .quaternaryLabelColor))
            .frame(width: 44, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 5))
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
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: draft) ?? Color(nsColor: .quaternaryLabelColor))
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.option.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(draft.isEmpty ? "no value" : draft)
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                TextField("#1e1e2e, tomato, cell-foreground", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitColor() }
                Button("Set") { commitColor() }
                    .disabled(!canApplyColorDraft)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 5), count: 8), spacing: 5) {
                ForEach(Self.colorPresets, id: \.self) { hex in
                    Button {
                        draft = hex
                        apply(hex)
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 22, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(isSelectedPreset(hex) ? Color.accentColor : Color(nsColor: .separatorColor),
                                                  lineWidth: isSelectedPreset(hex) ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(hex)
                }
            }
            Text("Type a hex code, an X11 color name, or cell-foreground / cell-background.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 250)
    }

    private func isSelectedPreset(_ hex: String) -> Bool {
        hex.caseInsensitiveCompare(currentValue) == .orderedSame
    }

    /// A blank field or one that matches the saved value is never a valid write.
    private var canApplyColorDraft: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != currentValue
    }

    private func commitColor() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != currentValue else { return }
        if value != draft { draft = value }
        apply(value)
        showingColorPopover = false
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
        .accessibilityLabel(Text(option.option.displayTitle))
    }

    // MARK: Slider

    private var sliderRange: ClosedRange<Double>? {
        guard let spec, let lo = spec.min, let hi = spec.max, lo < hi else { return nil }
        return lo...hi
    }

    private func sliderEditor(_ spec: NumericSpec, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Slider(value: $live, in: range, step: spec.step ?? 0.05) { editing in
                if !editing { commitSlider(spec) }
            }
            .frame(width: 120)
            Text(numberString(spec.clamp(live), decimals: decimals(for: spec)))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .accessibilityValue(Text(numberString(spec.clamp(live), decimals: decimals(for: spec))))
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
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .onSubmit { commitField(spec) }
            if let unit = spec.unit {
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Stepper("",
                    onIncrement: { stepField(spec, by: 1) },
                    onDecrement: { stepField(spec, by: -1) })
                .labelsHidden()
        }
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
        VStack(alignment: .trailing, spacing: 2) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onSubmit { commitUnclamped() }
            if let bytes = Double(draft.trimmingCharacters(in: .whitespaces)), bytes > 0 {
                Text(NumericSpec.formatBytes(bytes))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Plain (no spec)

    @ViewBuilder
    private var plainField: some View {
        let inferredStep = NumericSpec.inferredStep(forDefault: option.option.defaultValue)
        HStack(spacing: 4) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .onSubmit { commitUnclamped() }
            if inferredStep != 1 {
                // A fractional default earns a fine stepper; an integer default drops
                // it, since a whole-number nudge on an unbounded field is noise.
                Stepper("",
                        onIncrement: { stepUnclamped(by: inferredStep) },
                        onDecrement: { stepUnclamped(by: -inferredStep) })
                    .labelsHidden()
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
    /// enough places to render the step (capped at 3).
    private func decimals(for spec: NumericSpec) -> Int {
        let step = spec.step ?? 1
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

    /// The last "on" (non-`false`) value seen, so Off→On restores it rather than
    /// snapping to a bare `true`. Seeded from the saved value and kept in sync with it.
    @State private var lastOnValue: String?

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: onBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text(option.option.displayTitle))
            if !extraChoices.isEmpty {
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
    /// the trailing menu offers (with friendly labels, raw tags).
    private var extraChoices: [EnumChoice] {
        option.enumChoices(current: savedValue)
            .filter { $0.value != "true" && $0.value != "false" && !$0.value.isEmpty }
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
        if let primary = selected.first { return .custom(displayName(primary), size: 12) }
        return .system(size: 12)
    }

    // MARK: Popover

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(option.option.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

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

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                Text(name)
                    // Each name rendered in its own face, so the list reads like a
                    // font menu; unresolvable names fall back to the system font.
                    .font(.custom(name, size: 14))
                    .lineLimit(1)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                documentation
                Divider()
                metadata
                actions
            }
            .frame(width: 360, alignment: .leading)
            .padding(16)
        }
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
                Badge(text: option.option.category, systemImage: "folder")
                Badge(text: option.option.valueType.rawValue, systemImage: "tag")
                if option.option.isRepeatable {
                    Badge(text: "repeatable", systemImage: "plus.square.on.square")
                }
                stateBadge
            }
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch option.state {
        case .setNonDefault:
            Badge(text: "customized", systemImage: "pencil", tint: .accentColor)
        case .setToDefault:
            Badge(text: "at default", systemImage: "equal", tint: .secondary)
        case .unset:
            Badge(text: "not using yet", systemImage: "sparkles", tint: .orange)
        }
    }

    private var documentation: some View {
        Text(hasDoc ? option.option.documentation : "No documentation available.")
            .font(.callout)
            .foregroundStyle(hasDoc ? .primary : .secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            if option.isSet {
                LabeledRow("Your value") {
                    Text(option.userValues.map(\.strippingConfigQuotes).joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            LabeledRow("Default") {
                Text(option.option.defaultValue.isEmpty ? "—" : option.option.defaultValue.strippingConfigQuotes)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                copySnippet()
            } label: {
                Label(copied ? "Copied" : "Copy snippet", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            if let source = option.sources.first {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: source.file))
                } label: {
                    Label("Reveal in editor", systemImage: "arrow.up.forward.app")
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

private struct Badge: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
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
