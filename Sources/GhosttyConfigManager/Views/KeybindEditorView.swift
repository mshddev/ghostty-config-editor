import SwiftUI
import AppKit
import GhosttyConfigKit

/// The Keybindings editor surface: Ghostty's defaults merged with the user's
/// bindings, an action picker, the press-the-keys recorder, a raw-text fallback
/// for advanced grammar, and the existing footgun lint shown inline (RK1–RK4,
/// R16, AE4). Edits route through `AppModel` to the safe write path.
struct KeybindEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var didLoad = false
    @State private var editing: KeybindDraft?

    var body: some View {
        // Compute the merged list once per render (the header count and the list
        // both need it).
        let rows = model.mergedKeybinds
        return VStack(spacing: 0) {
            headerBar(count: rows.count)
            Divider()
            if !didLoad {
                ProgressView("Loading keybindings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .sheet(item: $editing) { draft in
            KeybindEditForm(draft: draft)
        }
    }

    private func headerBar(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(count) bindings")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.resetApplyState()
                editing = KeybindDraft(row: nil)
            } label: {
                Label("Add binding", systemImage: "plus")
            }
        }
        .padding(8)
    }

    private func bindingList(_ rows: [MergedKeybind]) -> some View {
        List(rows) { row in
            KeybindRow(row: row, isReadOnly: model.isReadOnly(row))
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !model.isReadOnly(row) else { return }
                    model.resetApplyState()
                    editing = KeybindDraft(row: row)
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

/// One row in the merged list: trigger, action, and an origin badge (RK1).
private struct KeybindRow: View {
    let row: MergedKeybind
    let isReadOnly: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(row.trigger)
                .font(.body.monospaced())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                .strikethrough(isDisabled, color: .secondary)
                .frame(minWidth: 140, alignment: .leading)

            Text(row.action)
                .font(.callout.monospaced())
                .foregroundStyle(isDisabled ? .tertiary : .secondary)

            Spacer()

            if isReadOnly, let source = row.source {
                Label("in \((source.file as NSString).lastPathComponent)", systemImage: "lock")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                badge
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.trigger), \(row.action), \(badgeText)")
    }

    private var isDisabled: Bool { row.origin == .userDisablesDefault }

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
        }
    }

    private var badgeTint: Color {
        switch row.origin {
        case .default: return .secondary
        case .userAdded: return .accentColor
        case .userOverridesDefault: return .orange
        case .userDisablesDefault: return .red
        }
    }
}

/// What the edit sheet is editing: an existing merged row, or a new binding.
struct KeybindDraft: Identifiable {
    var id: String { row?.id ?? "∅new" }
    let row: MergedKeybind?
}

/// The add/edit sheet: the recorder, a raw-text fallback, a searchable action
/// picker, live kit validation, and contextual remove/disable actions.
struct KeybindEditForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let draft: KeybindDraft
    @State private var trigger: String
    @State private var action: String
    @State private var actionQuery: String = ""
    @State private var recorderWarning: String?

    init(draft: KeybindDraft) {
        self.draft = draft
        // A default row prefills its trigger/action so editing the action creates
        // an override; a new binding starts blank.
        _trigger = State(initialValue: draft.row?.trigger ?? "")
        _action = State(initialValue: draft.row?.action ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.row == nil ? "New binding" : "Edit binding").font(.headline)

            triggerSection
            actionSection
            issuesSection
            writeFeedback

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 480)
    }

    /// A write that the kit's pre-validation didn't catch (e.g. the binary's
    /// `+validate-config` rejecting it, or a stale-on-disk conflict) keeps the
    /// sheet open — surface the reason here, where the user is looking, instead of
    /// only behind the sheet in the list's feedback bar.
    @ViewBuilder
    private var writeFeedback: some View {
        if case .failed(let message) = model.applyState {
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isApplying: Bool { model.applyState == .applying }

    // MARK: Trigger

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trigger").font(.subheadline.bold())
            KeyRecorderView(
                token: trigger,
                onCapture: { trigger = $0; recorderWarning = nil },
                onWarning: { recorderWarning = $0 }
            )
            .frame(height: 30)
            if let recorderWarning {
                Text(recorderWarning).font(.caption).foregroundStyle(.orange)
            }
            TextField("Or type a trigger (sequences, global:/unconsumed: prefixes…)", text: $trigger)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
        }
    }

    // MARK: Action

    private var filteredActions: [KeybindAction] {
        let all = model.keybindActions.sorted()
        let query = actionQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.contains(query) }
    }

    private var selectedActionName: String {
        if let colon = action.firstIndex(of: ":") { return String(action[..<colon]) }
        return action
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Action").font(.subheadline.bold())
            TextField("Search actions", text: $actionQuery)
                .textFieldStyle(.roundedBorder)
            if model.keybindActions.isEmpty {
                Text("Couldn’t load Ghostty’s action list — type the action name below.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredActions) { item in
                            Button {
                                selectAction(item.name)
                            } label: {
                                HStack {
                                    Text(item.name).font(.body.monospaced())
                                    Spacer()
                                    if item.name == selectedActionName {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .padding(.vertical, 4).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(item.name == selectedActionName ? Color.accentColor.opacity(0.15) : .clear)
                        }
                    }
                }
                .frame(height: 150)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            TextField("Action (with any :parameters, e.g. goto_tab:1)", text: $action)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
        }
    }

    /// Pick a base action name, preserving any `:parameters` already typed.
    private func selectAction(_ name: String) {
        if let colon = action.firstIndex(of: ":") {
            action = name + String(action[colon...])
        } else {
            action = name
        }
    }

    // MARK: Validation preview

    private var issues: [KeybindIssue] {
        guard !trigger.isEmpty, !action.isEmpty else { return [] }
        return KeybindValidation.validate(trigger: trigger, action: action, knownActions: model.keybindActionNames)
    }

    private var hasError: Bool { issues.contains { $0.severity == .error } }

    @ViewBuilder
    private var issuesSection: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Footer

    private var canSave: Bool {
        !trigger.trimmingCharacters(in: .whitespaces).isEmpty &&
        !action.trimmingCharacters(in: .whitespaces).isEmpty &&
        !hasError
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let row = draft.row {
                contextualActions(for: row)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                Task {
                    await model.applyKeybindEdit(originalTrigger: draft.row?.canonicalTrigger, trigger: trigger, action: action)
                    if case .failed = model.applyState { return }
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave || isApplying)
        }
    }

    @ViewBuilder
    private func contextualActions(for row: MergedKeybind) -> some View {
        switch row.origin {
        case .userAdded, .userOverridesDefault:
            Button("Remove", role: .destructive) {
                Task { await model.removeKeybind(trigger: row.canonicalTrigger); dismiss() }
            }
            .disabled(isApplying)
        case .default:
            Button("Disable") {
                Task { await model.unbindDefaultKeybind(trigger: row.canonicalTrigger); dismiss() }
            }
            .disabled(isApplying)
        case .userDisablesDefault:
            Button("Re-enable") {
                Task { await model.removeKeybind(trigger: row.canonicalTrigger); dismiss() }
            }
            .disabled(isApplying)
        }
    }
}
