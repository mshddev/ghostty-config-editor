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
            } else {
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
                    Text(option.option.name)
                        .font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
    @ViewBuilder
    private var editor: some View {
        if !option.option.isRepeatable {
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

    /// The default (or, for repeatable keys, the current values) — the inline
    /// control already shows the *current* scalar value, so the subtitle carries
    /// the complementary context instead of repeating it.
    private var subtitle: String {
        if option.option.isRepeatable {
            return option.isSet ? option.userValues.joined(separator: ", ") : "not set"
        }
        let def = option.option.defaultValue
        return def.isEmpty ? "no default" : "default: \(def)"
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
        switch option.option.valueType {
        case .boolean:
            Toggle("", isOn: boolBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
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
            HStack(spacing: 4) {
                TextField("value", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { commit() }
                Stepper("", value: numberBinding, step: 1).labelsHidden()
            }
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
            TextField("value", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onSubmit { commit() }
        }
    }

    private var currentValue: String {
        option.isSet ? (option.userValues.first ?? "") : option.option.defaultValue
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

    private var numberBinding: Binding<Double> {
        Binding(
            get: { Double(draft) ?? 0 },
            set: { value in
                let text = value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
                draft = text
                apply(text)
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
            Text(option.option.name)
                .font(.headline)
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
                    Text(option.userValues.joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            LabeledRow("Default") {
                Text(option.option.defaultValue.isEmpty ? "—" : option.option.defaultValue)
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
