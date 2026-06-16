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
        case .unused: return "Not Using Yet"
        case .problems: return "Problems"
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

/// One row in the option list: name, a state dot, and a short value summary.
struct OptionRow: View {
    let option: MergedOption

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
                .help(stateHelp)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.option.name)
                    .font(.body)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 1)
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
