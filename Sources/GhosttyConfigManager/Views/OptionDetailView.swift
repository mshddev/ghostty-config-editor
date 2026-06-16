import SwiftUI
import AppKit
import GhosttyConfigKit

/// The trailing column: documentation, default, the user's current value, a
/// discovery indicator for unused options, and read-only actions (M1). Editing
/// controls are layered on in U7.
struct OptionDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        if let option = model.selectedOption() {
            detail(for: option)
        } else {
            ContentUnavailableView("Select an option",
                                   systemImage: "sidebar.right",
                                   description: Text("Pick an option to see its docs, default, and your current value."))
        }
    }

    @ViewBuilder
    private func detail(for option: MergedOption) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(option)
                Divider()
                valueSection(option)
                if !option.option.enumValues.isEmpty {
                    enumSection(option)
                }
                Divider()
                editorSection(option)
                docSection(option)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(option.option.name)
        .toolbar { toolbar(option) }
    }

    private func header(_ option: MergedOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(option.option.name)
                .font(.title2).bold()
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Badge(text: option.option.category, systemImage: "folder")
                Badge(text: option.option.valueType.rawValue, systemImage: "tag")
                if option.option.isRepeatable {
                    Badge(text: "repeatable", systemImage: "plus.square.on.square")
                }
                stateBadge(option)
            }
        }
    }

    @ViewBuilder
    private func stateBadge(_ option: MergedOption) -> some View {
        switch option.state {
        case .setNonDefault:
            Badge(text: "customized", systemImage: "pencil", tint: .accentColor)
        case .setToDefault:
            Badge(text: "at default", systemImage: "equal", tint: .secondary)
        case .unset:
            Badge(text: "not using yet", systemImage: "sparkles", tint: .orange)
        }
    }

    private func valueSection(_ option: MergedOption) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if option.isSet {
                LabeledRow("Your value") {
                    Text(option.userValues.joined(separator: "\n"))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            } else {
                Text("You're not setting this — Ghostty uses the default below.")
                    .foregroundStyle(.secondary)
            }
            LabeledRow("Default") {
                Text(option.option.defaultValue.isEmpty ? "—" : option.option.defaultValue)
                    .font(.body.monospaced())
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

    private func enumSection(_ option: MergedOption) -> some View {
        LabeledRow("Valid values") {
            FlowText(option.option.enumValues)
        }
    }

    @ViewBuilder
    private func editorSection(_ option: MergedOption) -> some View {
        if option.option.isRepeatable {
            GroupBox {
                Label("This option can repeat (\(option.userValues.count) currently set). In-app list editing is coming; for now use Copy snippet or Reveal in editor.",
                      systemImage: "list.bullet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            OptionEditorView(option: option)
        }
    }

    private func docSection(_ option: MergedOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Documentation").font(.headline)
            Text(option.option.documentation.isEmpty ? "No documentation available." : option.option.documentation)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ option: MergedOption) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                copySnippet(option)
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
    }

    private func copySnippet(_ option: MergedOption) {
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

// MARK: - Editor (U7)

/// Type-appropriate editing controls for a scalar option, with apply feedback
/// (R13, R17). Validates against the live binary before writing (via AppModel).
struct OptionEditorView: View {
    @Environment(AppModel.self) private var model
    let option: MergedOption
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit").font(.headline)
            control
            HStack(spacing: 12) {
                Button("Apply") {
                    Task { await model.applyEdit(option: option, values: [draft]) }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isDirty || isApplying)

                if isDirty {
                    Button("Reset") { draft = currentValue }
                        .buttonStyle(.link)
                }
                Spacer()
            }
            feedback
        }
        .padding(.vertical, 2)
        .onAppear { draft = currentValue }
        .onChange(of: option.id) { _, _ in
            draft = currentValue
            model.resetApplyState()
        }
    }

    private var currentValue: String {
        option.isSet ? (option.userValues.first ?? "") : option.option.defaultValue
    }
    private var isDirty: Bool { draft != currentValue }
    private var isApplying: Bool { model.applyState == .applying }

    @ViewBuilder
    private var control: some View {
        switch option.option.valueType {
        case .boolean:
            Toggle(isOn: boolBinding) { Text(draft == "true" ? "Enabled" : "Disabled") }
                .toggleStyle(.switch)
        case .enumeration:
            Picker("Value", selection: $draft) {
                ForEach(option.option.enumValues, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        case .number:
            HStack(spacing: 8) {
                TextField("value", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Stepper("", value: numberBinding, step: 1).labelsHidden()
            }
        default:
            TextField("value", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
        }
    }

    private var boolBinding: Binding<Bool> {
        Binding(get: { draft == "true" }, set: { draft = $0 ? "true" : "false" })
    }

    private var numberBinding: Binding<Double> {
        Binding(
            get: { Double(draft) ?? 0 },
            set: { value in
                draft = value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
            }
        )
    }

    @ViewBuilder
    private var feedback: some View {
        switch model.applyState {
        case .idle:
            EmptyView()
        case .applying:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Validating and saving…").font(.caption) }
        case .succeeded(let notice, let gitTracked):
            VStack(alignment: .leading, spacing: 3) {
                Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if gitTracked {
                    Text("This file is git-tracked — commit it in your dotfiles repo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.canUndo {
                    Button("Undo") { Task { await model.undoLastApply() } }.buttonStyle(.link)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
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

private struct FlowText: View {
    let values: [String]
    init(_ values: [String]) { self.values = values }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}
