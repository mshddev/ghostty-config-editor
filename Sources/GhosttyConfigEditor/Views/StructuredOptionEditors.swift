import SwiftUI
import AppKit
import GhosttyConfigKit

// The structured and repeatable-setting editors, extracted from
// OptionListView so the option row dispatches through one tested routing policy and the
// large list/path/flag editors live together. Every editor here routes its writes through
// the model's existing safe apply path; the structured parsers keep a raw fallback so
// unknown/future values round-trip verbatim.

// MARK: - Editor routing policy

/// Which editor renders an option row. A pure value so the "no editable repeatable ends
/// as an info-only dead row" guarantee is a tested app-logic fact instead of something
/// buried in a SwiftUI ViewBuilder. `OptionRow.editor` switches on this, and
/// `PresentationPolicyTests` asserts no editable repeatable ever resolves to `.infoOnly`.
enum OptionEditorRoute: Equatable {
    case fontFamily        // dedicated: font-family[-bold/-italic…]
    case palette           // dedicated: 16-swatch ANSI grid
    case fontFeature       // dedicated: Ligatures toggle + per-tag list
    case scrollMultiplier  // two-field precision/discrete composite
    case bellFeatures      // labeled flag-set toggles
    case pathChooser       // single folder/file chooser + raw entry (working-directory)
    case pathList          // repeatable add/remove list with a file chooser (config-file)
    case repeatableList    // generic ordered add/remove list (command-palette-entry, env, …)
    case keybindDeepLink   // keybind is edited on its own Keyboard Shortcuts surface
    case color             // shared color editor (selection-*, unfocused-split-fill, …)
    case inline            // scalar inline control (toggle/picker/number/text)
    /// The forbidden state: an editable repeatable with no editor. The resolver must
    /// never return this for an editable repeatable; only a read-only/excluded row does.
    case infoOnly

    static func resolve(for option: CatalogOption) -> OptionEditorRoute {
        let presentation = option.presentation
        return resolve(
            name: option.name,
            editorKind: presentation.editorKind,
            editability: presentation.editability,
            isRepeatable: option.isRepeatable,
            valueType: option.valueType
        )
    }

    /// The primitive form, so the routing policy is exhaustively testable across every
    /// `OptionEditorKind` without constructing a full catalog (structural guard).
    static func resolve(
        name: String,
        editorKind: OptionEditorKind,
        editability: OptionEditability,
        isRepeatable: Bool,
        valueType: OptionValueType
    ) -> OptionEditorRoute {
        // A read-only/excluded row never renders an editable control; the guarantee only governs
        // editable rows, so this is the one legitimate `.infoOnly`.
        guard editability == .editable else { return .infoOnly }

        // Dedicated names win over the generic kind (they keep their bespoke surfaces).
        if name.hasPrefix("font-family") { return .fontFamily }
        if name == "palette" { return .palette }
        if name == "font-feature" { return .fontFeature }

        switch editorKind {
        case .scrollMultiplier: return .scrollMultiplier
        case .flagSet: return .bellFeatures
        case .path: return .pathChooser
        case .pathList: return .pathList
        case .repeatableList: return .repeatableList
        case .color: return .color
        case .dedicated:
            // keybind has a real dedicated surface; the remaining dedicated repeatables
            // (env, codepoint maps, font-variation…) get the lossless generic list.
            return name == "keybind" ? .keybindDeepLink : .repeatableList
        case .automatic:
            if valueType == .color { return .color }
            // A repeatable with no override still needs a real editor — the generic list is
            // the safety net so a new repeatable Ghostty option is never a dead row.
            return isRepeatable ? .repeatableList : .inline
        }
    }
}

// MARK: - Shared transactional commit + stale recovery

/// Commit + recovery contract shared by the text-bearing structured popovers (the scroll
/// multiplier and path editors) so the stale-on-disk Reload & Review path can't drift out of
/// them — they previously only `markFailed`, dead-ending an external-file conflict instead of
/// offering recovery. Mirrors `InlineOptionEditor`'s color/long-value contract.
enum TransactionApply {
    /// Apply the draft through the SAME safe write path (`model.applyEdit`), mapping the
    /// outcome onto the transaction: success commits + closes; a stale conflict awaits an
    /// explicit Reload & Review (never auto-retry); any other rejection retains the draft
    /// under a normalized message. `beginApply` makes this one write despite repeated
    /// draft callbacks.
    @MainActor
    static func commit(
        _ transaction: Binding<EditTransaction>,
        option: MergedOption,
        values: [String],
        model: AppModel,
        close: @escaping () -> Void
    ) {
        guard transaction.wrappedValue.beginApply() else { return }
        Task {
            await model.applyEdit(option: option, values: values)
            switch model.applyState {
            case .succeeded:
                transaction.wrappedValue.markCommitted()
                close()
            case .failed(let presentation) where presentation.offersReload:
                transaction.wrappedValue.markStale(message: presentation.message)
            case .failed(let presentation):
                transaction.wrappedValue.markFailed(message: presentation.message)
            default:
                break
            }
        }
    }

    /// Stale recovery: reload disk, then surface the externally-changed value beside
    /// the retained draft so a SECOND explicit Apply reconciles; if the option vanished, stop
    /// with an actionable message and leave Apply disabled rather than guessing a target.
    @MainActor
    static func reloadAndReview(
        _ transaction: Binding<EditTransaction>,
        optionName: String,
        model: AppModel
    ) {
        Task {
            await model.reloadFromDisk()
            if let disk = model.savedValue(forOptionNamed: optionName) {
                transaction.wrappedValue.reloadAndReview(refreshedDiskValue: disk)
            } else {
                transaction.wrappedValue.markTargetUnavailable(
                    message: "This setting is no longer in your config. Close and reopen to continue.")
            }
        }
    }
}

/// Shared inline status for a text-bearing popover: the local/validation/stale
/// message, a Reload & Review action for a stale conflict, and the side-by-side disk-vs-draft
/// comparison after a reload. `reload` should run `TransactionApply.reloadAndReview`.
@ViewBuilder
func transactionStatusView(_ transaction: EditTransaction, reload: @escaping () -> Void) -> some View {
    if let message = transaction.message {
        Label(message, systemImage: transaction.isStale ? "arrow.triangle.2.circlepath"
                                                        : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(transaction.isStale ? Color.secondary : Color.red)
            .fixedSize(horizontal: false, vertical: true)
    }
    if transaction.isStale {
        Button("Reload & Review", action: reload).font(.caption)
    }
    if let disk = transaction.refreshedDiskValue, transaction.isDirty {
        Text("Now on disk: \(disk) — Apply again to replace it with \(transaction.draft).")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Shared live-option lookup

extension MergedOption {
    /// The freshest form of this option: re-read from the live merged model so a structured
    /// editor reflects an external edit or a just-applied write, falling back to this snapshot
    /// when the browser hasn't loaded or the option has since vanished. Single-sourced here so
    /// the stale-recovery lookup can't drift across the editors — the copy-paste that let some
    /// editors dead-end an external-file conflict before it was consolidated.
    @MainActor
    func live(in model: AppModel) -> MergedOption {
        model.browser?.merged.option(named: option.name) ?? self
    }
}

// MARK: - Keybind deep link

/// keybind is edited on the dedicated Keyboard Shortcuts surface, so in a category/search row
/// its editor is a jump there rather than a raw inline control — an action, never an info-only
/// dead end, and it "still routes to its dedicated surface".
struct KeybindDeepLinkButton: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption

    var body: some View {
        Button { model.focus(optionNamed: "keybind") } label: {
            HStack(spacing: 4) {
                Image(systemName: "keyboard").imageScale(.small)
                Text("Edit in Shortcuts")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Edit keyboard shortcuts on their dedicated surface")
        .accessibilityLabel("Edit \(option.option.displayTitle) in Keyboard Shortcuts")
    }
}

// MARK: - Generic repeatable list editor

/// An add/remove/reorder list for repeatable text options (`env`, `config-file`,
/// `command-palette-entry`, and any repeatable without a bespoke editor) — the proven
/// "Edit…" popover over a list of value rows, each write routed through the safe repeatable
/// path. Unknown/future values round-trip verbatim: a row is stored and rewritten as
/// its exact raw string. With `allowsPathChooser`, the add row also offers an
/// NSOpenPanel chooser so path-shaped repeatables (`config-file`) can pick a file.
struct RepeatableListEditor: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption
    /// A fixed button label — e.g. font-feature's "Customize…" disclosure — instead of the
    /// default "Add…"/"N set" count.
    var customLabel: String? = nil
    /// When true, the add row offers a "Choose File…" NSOpenPanel that appends the picked
    /// path (path-shaped repeatables like `config-file`).
    var allowsPathChooser: Bool = false
    @State private var showing = false
    @State private var newEntry = ""

    private var liveOption: MergedOption { option.live(in: model) }
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
                    entryRow(index: index, entry: entry, count: entries.count)
                }
            }
            Divider()
            HStack(spacing: 6) {
                TextField(placeholder, text: $newEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                if allowsPathChooser {
                    Button { chooseFile() } label: { Image(systemName: "folder") }
                        .help("Choose a file")
                        .accessibilityLabel("Choose a file")
                }
                Button("Add") { add() }
                    .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func entryRow(index: Int, entry: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(entry)
                .font(.callout.monospaced())
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            // Reorder controls ("add, remove, reorder") — dimmed at the ends so the
            // list order is directly editable rather than requiring a delete/re-add.
            Button { move(from: index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(index == 0)
                .help("Move up").accessibilityLabel("Move \(entry) up")
            Button { move(from: index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(index == count - 1)
                .help("Move down").accessibilityLabel("Move \(entry) down")
            Button { remove(at: index) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Remove").accessibilityLabel("Remove \(entry)")
        }
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

    /// Reorder one entry, preserving every other value's raw form (round-trip).
    private func move(from index: Int, by delta: Int) {
        var next = entries
        let target = index + delta
        guard next.indices.contains(index), next.indices.contains(target) else { return }
        next.swapAt(index, target)
        apply(next)
    }

    /// An NSOpenPanel file chooser for path-shaped repeatables; the picked path is appended
    /// as a new entry. A free-form/inherited value can still be typed in the field.
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let path = panel.url?.path {
            apply(entries + [path])
        }
    }

    private func apply(_ values: [String]) {
        Task { await model.applyEdit(option: liveOption, values: values) }
    }
}

// MARK: - Font-feature (Ligatures) editor

/// `font-feature` (titled "Ligatures") rendered toggle-first: the common case is
/// "ligatures on or off", so a switch drives that — On strips Ghostty's `-calt, -liga,
/// -dlig` disable set, Off writes it — over the kit `FontFeatures` tag arithmetic that
/// preserves any user-added stylistic tags. The full per-tag list stays reachable behind
/// a secondary "Customize…" disclosure for `ss01`-style sets.
struct FontFeatureEditor: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption

    /// Read the value in force from the live merged model, so the toggle reflects an
    /// external edit or a just-applied write.
    private var liveOption: MergedOption { option.live(in: model) }
    private var values: [String] { liveOption.isSet ? liveOption.userValues : [] }

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: ligatureBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(optionControlA11yLabel(option))
            RepeatableListEditor(option: option, customLabel: "Customize…")
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

// MARK: - Scroll-multiplier editor

/// A two-field editor for `mouse-scroll-multiplier`: separate precision and discrete
/// multipliers instead of the raw `precision:…,discrete:…` mini-language. Backed by the pure
/// `ScrollMultiplierValue`, so unknown/bare fragments round-trip verbatim. Text-bearing,
/// so it uses the transaction: Apply commits, Cancel/dismiss discards.
struct ScrollMultiplierEditor: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption
    @State private var showing = false
    @State private var transaction = EditTransaction(savedValue: "")

    private var liveOption: MergedOption { option.live(in: model) }
    private var savedValue: String { liveOption.valuePresentation.value ?? "" }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3").imageScale(.small)
                Text(summary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Edit scroll multipliers")
        .accessibilityLabel(optionControlA11yLabel(option))
        .popover(isPresented: $showing, arrowEdge: .bottom) { editor }
        .onChange(of: showing) { _, open in
            if open { transaction = EditTransaction(savedValue: savedValue) }
            else {
                transaction.cancel()
                model.dismissApplyFailure(forOptionNamed: option.option.name)
            }
        }
    }

    private var summary: String {
        let value = ScrollMultiplierValue.parse(savedValue)
        let precision = value.precision ?? "1"   // Ghostty's documented precision default
        let discrete = value.discrete ?? "3"     // Ghostty's documented discrete default
        return "×\(precision) / ×\(discrete)"
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(option.option.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Precision (trackpad)").font(.callout)
                    TextField("1", text: fieldBinding(\.precision))
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                        .onSubmit { commit() }
                }
                GridRow {
                    Text("Discrete (mouse wheel)").font(.callout)
                    TextField("3", text: fieldBinding(\.discrete))
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                        .onSubmit { commit() }
                }
            }
            if !parsedDraft.unknown.isEmpty {
                Text("Other values kept: \(parsedDraft.unknown.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Blank keeps Ghostty's default (×1 precision, ×3 discrete).")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            transactionStatusView(transaction) {
                TransactionApply.reloadAndReview($transaction, optionName: option.option.name, model: model)
            }
            HStack {
                Spacer()
                Button("Cancel") { showing = false }
                Button("Apply") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!transaction.canApply)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    /// The composite parsed from the current draft, so edits to one field preserve the other
    /// field and any unknown fragments.
    private var parsedDraft: ScrollMultiplierValue { ScrollMultiplierValue.parse(transaction.draft) }

    /// A binding to one labeled field: reads/writes through the parsed composite so the raw
    /// draft string stays the single source of truth the transaction commits.
    private func fieldBinding(_ key: WritableKeyPath<ScrollMultiplierValue, String?>) -> Binding<String> {
        Binding(
            get: { parsedDraft[keyPath: key] ?? "" },
            set: { newValue in
                var composite = parsedDraft
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                composite[keyPath: key] = trimmed.isEmpty ? nil : trimmed
                transaction.edit(composite.serialized())
            }
        )
    }

    /// Commit the composite through the shared safe apply path; an empty result unsets the
    /// option. Routes stale-on-disk conflicts to Reload & Review like the color editor.
    private func commit() {
        TransactionApply.commit($transaction, option: liveOption,
                                values: transaction.draft.isEmpty ? [] : [transaction.draft],
                                model: model, close: { showing = false })
    }
}

// MARK: - Bell-features editor

/// A labeled multi-choice editor for `bell-features`: a checkbox per documented feature
/// instead of the raw `no-system,attention,…` flag string. Backed by the pure
/// `BellFeaturesValue`, so omitted/default features and unknown tokens round-trip verbatim
/// while toggling one labeled feature. Each toggle writes immediately (a discrete choice,
/// like the palette swatches — no text-bearing draft to stage).
struct BellFeaturesEditor: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption
    @State private var showing = false

    private var liveOption: MergedOption { option.live(in: model) }
    private var savedValue: String { liveOption.valuePresentation.value ?? "" }
    private var parsed: BellFeaturesValue { BellFeaturesValue.parse(savedValue) }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "bell").imageScale(.small)
                Text("\(enabledCount) on")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Choose bell features")
        .accessibilityLabel(optionControlA11yLabel(option))
        .popover(isPresented: $showing, arrowEdge: .bottom) { editor }
    }

    private var enabledCount: Int {
        BellFeaturesValue.knownFeatures.filter { parsed.isEnabled($0.name) }.count
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(option.option.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
            ForEach(BellFeaturesValue.knownFeatures, id: \.name) { feature in
                Toggle(isOn: binding(for: feature.name)) {
                    Text(feature.name.capitalized).font(.callout)
                }
                .toggleStyle(.checkbox)
            }
            if !unknownTokens.isEmpty {
                Divider()
                Text("Other values kept: \(unknownTokens.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if liveOption.isSet {
                Divider()
                Button("Reset to default") { apply("") }
                    .controlSize(.small)
                    .help("Clear these choices and use Ghostty's defaults")
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    /// Tokens the editor doesn't model as labeled features — shown so the user knows they're
    /// preserved, never silently dropped.
    private var unknownTokens: [String] {
        let known = Set(BellFeaturesValue.knownFeatures.map(\.name))
        return parsed.tokens.filter { token in
            let base = token.lowercased().hasPrefix("no-") ? String(token.dropFirst(3)) : token
            return !known.contains(base.lowercased())
        }
    }

    /// A checkbox binding for one feature: toggling replaces/appends exactly that feature's
    /// token via the pure model, preserving every omitted feature and unknown token.
    private func binding(for feature: String) -> Binding<Bool> {
        Binding(
            get: { parsed.isEnabled(feature) },
            set: { enabled in
                var value = parsed
                value.set(feature, enabled: enabled)
                apply(value.serialized())
            }
        )
    }

    /// Write the whole serialized value (single-valued option); an empty string unsets it.
    private func apply(_ value: String) {
        Task { await model.applyEdit(option: liveOption, values: value.isEmpty ? [] : [value]) }
    }
}

// MARK: - Path chooser editor

/// A single folder/file chooser for `working-directory`: an NSOpenPanel plus raw text
/// entry, so a chosen directory serializes exactly while a free-form or inherited value
/// (`window-inherit-working-directory`) still round-trips and an unset/default state is
/// representable. Text-bearing, so raw entry uses the transaction (Apply commits,
/// Cancel/dismiss discards).
struct PathChooserEditor: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption
    @State private var showing = false
    @State private var transaction = EditTransaction(savedValue: "")

    private var liveOption: MergedOption { option.live(in: model) }
    private var savedValue: String { liveOption.valuePresentation.value ?? "" }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder").imageScale(.small)
                Text(savedValue.isEmpty ? "Choose…" : shortened(savedValue))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(savedValue.isEmpty ? "Choose a folder" : savedValue)
        .accessibilityLabel(optionControlA11yLabel(option))
        .accessibilityValue(Text(savedValue.isEmpty ? "not set" : savedValue))
        .popover(isPresented: $showing, arrowEdge: .bottom) { editor }
        .onChange(of: showing) { _, open in
            if open { transaction = EditTransaction(savedValue: savedValue) }
            else {
                transaction.cancel()
                model.dismissApplyFailure(forOptionNamed: option.option.name)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(option.option.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
            Button { chooseFolder() } label: {
                Label("Choose Folder…", systemImage: "folder")
            }
            .controlSize(.small)
            TextField("/path/to/folder", text: draftBinding)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .frame(width: 320)
                .onSubmit { commit() }
            Text("A folder path, or a value like window-inherit-working-directory.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            transactionStatusView(transaction) {
                TransactionApply.reloadAndReview($transaction, optionName: option.option.name, model: model)
            }
            HStack {
                if liveOption.isSet {
                    Button("Reset") { apply([]) ; showing = false }
                        .controlSize(.small)
                        .help("Clear this and use Ghostty's default")
                }
                Spacer()
                Button("Cancel") { showing = false }
                Button("Apply") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!transaction.canApply)
            }
        }
        .padding(12)
        .frame(width: 344)
    }

    private var draftBinding: Binding<String> {
        Binding(get: { transaction.draft }, set: { transaction.edit($0) })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let path = panel.url?.path {
            transaction.edit(path)   // stage the pick; Apply commits
        }
    }

    /// The last path component with a leading ellipsis, so a long path stays legible on the
    /// bordered button.
    private func shortened(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return path == last ? path : "…/\(last)"
    }

    /// Commit the path through the shared safe apply path; routes stale-on-disk conflicts to
    /// Reload & Review like the color editor, not a dead-end error.
    private func commit() {
        TransactionApply.commit($transaction, option: liveOption,
                                values: transaction.draft.isEmpty ? [] : [transaction.draft],
                                model: model, close: { showing = false })
    }

    private func apply(_ values: [String]) {
        Task { await model.applyEdit(option: liveOption, values: values) }
    }
}
