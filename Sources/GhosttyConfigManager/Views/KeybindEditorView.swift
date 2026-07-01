import SwiftUI
import AppKit
import GhosttyConfigKit

/// The Keybindings editor surface: Ghostty's whole action set as one row per action
/// (defaults + the user's bindings + every still-unbound action), each editable
/// **inline** — click its shortcut and press the new keys, exactly like a system
/// shortcuts pane (RK1–RK4, R16, AE4). There is no modal: advanced grammar and extra
/// shortcuts live in each row's `⋯` menu. Edits route through `AppModel` to the safe
/// write path, and the existing footgun lint is shown inline.
struct KeybindEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var didLoad = false
    @State private var filter = ""

    var body: some View {
        let all = model.mergedKeybinds
        let rows = filtered(all)
        return VStack(spacing: 0) {
            headerBar(all: all)
            Divider()
            if !didLoad {
                ProgressView("Loading keybindings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                bindingList(rows)
            }
            lintBar
            feedbackBar
        }
        .navigationTitle("Keybindings")
        .task {
            await model.loadKeybindReferenceIfNeeded()
            didLoad = true
        }
    }

    /// Filter by action name or shortcut text (case-insensitive), so ~140 rows stay
    /// navigable.
    private func filtered(_ rows: [MergedKeybind]) -> [MergedKeybind] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.action.lowercased().contains(q)
                || $0.trigger.lowercased().contains(q)
                || KeybindTrigger.displaySymbol(for: $0.trigger).lowercased().contains(q)
        }
    }

    private func headerBar(all: [MergedKeybind]) -> some View {
        let boundCount = all.filter { $0.origin != .unbound }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(boundCount) shortcuts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.applyState == .applying {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            searchField
            Text("Click a shortcut and press the new keys to rebind. Actions with no shortcut are listed too.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Filter by action or shortcut", text: $filter)
                .textFieldStyle(.plain)
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }

    private func bindingList(_ rows: [MergedKeybind]) -> some View {
        List(rows) { row in
            KeybindRow(row: row, isReadOnly: model.isReadOnly(row))
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

    @ViewBuilder
    private var feedbackBar: some View {
        if case .failed(let message) = model.applyState {
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
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
/// trigger on the right as an **inline key recorder** — click and press the new chord
/// to (re)bind. Everything else lives in the trailing `⋯` menu: type an advanced
/// trigger, add a second shortcut, disable/remove/re-enable. Out-of-target bindings
/// render read-only (Risk R-F); unbound actions render as an empty, bindable row.
private struct KeybindRow: View {
    @Environment(AppModel.self) private var model
    let row: MergedKeybind
    let isReadOnly: Bool

    /// A soft, transient warning from the recorder (e.g. "add a modifier").
    @State private var warning: String?
    /// "Edit as text" popover (advanced trigger grammar for this row's binding).
    @State private var showingText = false
    @State private var textDraft = ""
    /// "Add another shortcut" popover (a second trigger for this row's action).
    @State private var showingAddAnother = false
    @State private var addAnotherDraft = ""

    /// Fixed width for the trigger control so every row's recorder/pill lines up.
    private static let triggerWidth: CGFloat = 190

    var body: some View {
        HStack(spacing: 12) {
            actionColumn
            Spacer(minLength: 12)
            trigger
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.action), \(triggerAccessibilityValue), \(badgeText)")
    }

    private var isDisabled: Bool { row.origin == .userDisablesDefault }
    private var isUnbound: Bool { row.origin == .unbound }

    private var triggerAccessibilityValue: String {
        isUnbound ? "no shortcut" : "bound to \(KeybindTrigger.displaySymbol(for: row.trigger))"
    }

    // MARK: Action (the config item)

    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.action)
                .font(.body.monospaced())
                .foregroundStyle(actionColor)
                .strikethrough(isDisabled, color: .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                badge
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var actionColor: HierarchicalShapeStyle {
        if isDisabled { return .tertiary }
        if isUnbound { return .secondary }
        return .primary
    }

    // MARK: Trigger (the inline recorder)

    @ViewBuilder
    private var trigger: some View {
        if isReadOnly {
            readOnlyTrigger
        } else if isDisabled {
            disabledTrigger
        } else {
            editableTrigger
        }
    }

    /// Default / user / override / unbound rows: an inline recorder (empty for an
    /// unbound action) plus the `⋯` menu.
    private var editableTrigger: some View {
        HStack(spacing: 6) {
            KeyRecorderView(
                token: row.trigger,
                onCapture: { setTrigger($0) },
                onWarning: { warning = $0 }
            )
            .frame(width: Self.triggerWidth, height: 30)
            actionsMenu
        }
    }

    /// A binding defined in another file: shown but not editable here (Risk R-F).
    private var readOnlyTrigger: some View {
        HStack(spacing: 6) {
            triggerPill(strikethrough: false)
            if let source = row.source {
                Label("in \((source.file as NSString).lastPathComponent)", systemImage: "lock")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// A default the user turned off: struck-through trigger with a one-click re-enable.
    private var disabledTrigger: some View {
        HStack(spacing: 6) {
            triggerPill(strikethrough: true)
            Button {
                perform { await model.removeKeybind(trigger: row.canonicalTrigger) }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Re-enable this default binding")
        }
    }

    private func triggerPill(strikethrough: Bool) -> some View {
        Text(KeybindTrigger.displaySymbol(for: row.trigger))
            .font(.body)
            .foregroundStyle(strikethrough ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .strikethrough(strikethrough, color: .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(width: Self.triggerWidth, alignment: .leading)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Trailing actions menu

    private var actionsMenu: some View {
        Menu {
            Button("Edit as text…") {
                textDraft = row.trigger
                showingText = true
            }
            if !isUnbound {
                Button("Add another shortcut…") {
                    addAnotherDraft = ""
                    showingAddAnother = true
                }
            }
            menuOriginActions
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .popover(isPresented: $showingText, arrowEdge: .bottom) { textEditor }
        .popover(isPresented: $showingAddAnother, arrowEdge: .bottom) { addAnotherEditor }
    }

    @ViewBuilder
    private var menuOriginActions: some View {
        switch row.origin {
        case .default:
            Divider()
            Button("Disable this default") {
                perform { await model.unbindDefaultKeybind(trigger: row.canonicalTrigger) }
            }
        case .userAdded:
            Divider()
            Button("Remove binding", role: .destructive) {
                perform { await model.removeKeybind(trigger: row.canonicalTrigger) }
            }
        case .userOverridesDefault:
            Divider()
            Button("Reset to default", role: .destructive) {
                perform { await model.removeKeybind(trigger: row.canonicalTrigger) }
            }
        case .userDisablesDefault, .unbound:
            EmptyView()
        }
    }

    // MARK: Inline popovers (advanced grammar / extra shortcut)

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trigger for \(row.action)")
                .font(.callout.weight(.semibold)).lineLimit(1)
            TextField("e.g. global:ctrl+a>n", text: $textDraft)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit { commitText() }
            Text("Supports sequences (ctrl+a>n) and prefixes (global:, unconsumed:, all:, performable:).")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { showingText = false }
                Button(isUnbound ? "Bind" : "Save") { commitText() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(textDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var addAnotherEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Additional shortcut for \(row.action)")
                .font(.callout.weight(.semibold)).lineLimit(1)
            KeyRecorderView(
                token: "",
                onCapture: { token in showingAddAnother = false; addAnother(token) },
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

    private func commitText() {
        let token = textDraft.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        showingText = false
        setTrigger(token)
    }

    private func commitAddAnother() {
        let token = addAnotherDraft.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        showingAddAnother = false
        addAnother(token)
    }

    // MARK: Write actions

    /// Set (or move) *this row's* trigger to `token`. Pressing the keys already bound
    /// is a no-op. A default moves to the new keys and disables its old default; an
    /// unbound action gains its first binding; a user binding moves in place.
    private func setTrigger(_ token: String) {
        warning = nil
        let token = token.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        if !row.canonicalTrigger.isEmpty,
           KeybindTrigger.parse(token).canonical() == row.canonicalTrigger { return }
        perform {
            switch row.origin {
            case .default:
                await model.rebindDefaultKeybind(oldTrigger: row.trigger, newTrigger: token, action: row.action)
            case .unbound:
                await model.applyKeybindEdit(originalTrigger: nil, trigger: token, action: row.action)
            case .userAdded, .userOverridesDefault, .userDisablesDefault:
                await model.applyKeybindEdit(originalTrigger: row.canonicalTrigger, trigger: token, action: row.action)
            }
        }
    }

    /// Add an *additional* shortcut for this row's action, never moving the existing
    /// one (Ghostty accepts multiple triggers for the same action).
    private func addAnother(_ token: String) {
        warning = nil
        let token = token.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        perform {
            await model.applyKeybindEdit(originalTrigger: nil, trigger: token, action: row.action)
        }
    }

    /// Run a model write with a clean apply state so this row's operation isn't
    /// shadowed by stale feedback from a previous edit.
    private func perform(_ work: @escaping () async -> Void) {
        model.resetApplyState()
        Task { await work() }
    }

    // MARK: Origin badge

    private var badge: some View {
        Text(badgeText)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(badgeTint.opacity(0.15), in: Capsule())
            .foregroundStyle(badgeTint)
    }

    private var badgeText: String {
        switch row.origin {
        case .default: return "default"
        case .userAdded: return "yours"
        case .userOverridesDefault(let action): return "overrides \(action)"
        case .userDisablesDefault: return "disabled"
        case .unbound: return "no shortcut"
        }
    }

    private var badgeTint: Color {
        switch row.origin {
        case .default: return .secondary
        case .userAdded: return .accentColor
        case .userOverridesDefault: return .orange
        case .userDisablesDefault: return .red
        case .unbound: return .secondary
        }
    }
}
