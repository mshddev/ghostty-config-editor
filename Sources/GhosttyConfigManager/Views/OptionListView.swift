import SwiftUI
import GhosttyConfigKit

/// The middle column: a searchable list of options for the current selection.
/// Search is intent-aware (R4) and name/doc full-text (R3).
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
        .navigationSplitViewColumnWidth(min: 260, ideal: 320)
    }

    private var title: String {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty { return "Search" }
        switch model.selection {
        case .category(let c): return c
        case .customized: return "Customized"
        case .problems: return "Problems"
        case .themes: return "Themes"
        case .all, .none: return "All Options"
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

/// One row in the option list: name, a state dot, a short value summary, and an
/// info button that reveals the option's full documentation in a popover.
struct OptionRow: View {
    let option: MergedOption
    @State private var showingDoc = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
                .help(stateHelp)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.option.name)
                    .font(.body)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            infoButton
        }
        .padding(.vertical, 1)
    }

    /// The docs live one click (or hover) from every option, not just the
    /// selected one — hover shows the full text as a native tooltip, click
    /// opens the richer, selectable popover.
    private var infoButton: some View {
        Button {
            showingDoc.toggle()
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(docHelp)
        .accessibilityLabel("Documentation for \(option.option.name)")
        .popover(isPresented: $showingDoc, arrowEdge: .trailing) {
            DocumentationPopover(option: option)
        }
    }

    private var docHelp: String {
        let doc = option.option.documentation
        return doc.isEmpty ? "No documentation available." : doc
    }

    private var summary: String {
        if option.isSet {
            return option.userValues.joined(separator: ", ")
        }
        let def = option.option.defaultValue
        return def.isEmpty ? "not set" : "default: \(def)"
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

/// The documentation popover anchored to a row's info button. Scrollable and
/// width-constrained so long docs stay readable; text is selectable so users
/// can copy examples out.
private struct DocumentationPopover: View {
    let option: MergedOption

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(option.option.name)
                    .font(.headline)
                    .textSelection(.enabled)
                Text(hasDoc ? option.option.documentation : "No documentation available.")
                    .font(.callout)
                    .foregroundStyle(hasDoc ? .primary : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 360, alignment: .leading)
            .padding(16)
        }
        .frame(maxHeight: 420)
    }

    private var hasDoc: Bool { !option.option.documentation.isEmpty }
}
