import SwiftUI
import GhosttyConfigKit

/// The leading column is reserved for places where users actively edit or explore.
/// Infrequent maintenance summaries (environment health, Customized, and Problems) live
/// behind the pinned Status row instead of competing with those primary destinations.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    /// The sidebar's selection reads as **nil while a global Find is in progress** (IA-3),
    /// so no category stays falsely highlighted when the detail pane is showing Find
    /// results instead. Writing through ends Find on *any* pick and navigates: the setter
    /// calls `endFind()` explicitly rather than relying on the app's `onChange(selection)`,
    /// because re-picking the row Find was started from writes an **equal** selection —
    /// which `onChange` wouldn't fire, leaving the click dead. When Find ends, the previous
    /// highlight returns. Customized/Problems are Status drill-downs, so the footer stays
    /// selected while either secondary surface is open.
    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(get: { displayedSelection },
                set: { newValue in
                    if model.isFinding { model.endFind() }
                    model.selection = newValue
                })
    }

    private var displayedSelection: SidebarSelection? {
        guard !model.isFinding else { return nil }
        switch model.selection {
        case .customized, .problems: return .status
        default: return model.selection
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The scrolling editing destinations. Each row carries an `.id` matching its
            // selection so restored/category navigation can scroll into view at short heights.
            ScrollViewReader { proxy in
                List(selection: sidebarSelection) {
                    // Get started — the exploratory surfaces a newcomer opens first.
                    // Recommended is pinned at the top (the curated "start here" set, F1);
                    // the app still *launches* on Themes to preserve its identity (OQ #2).
                    Section("Get started") {
                        Label("Recommended", systemImage: "sparkles")
                            .tag(SidebarSelection.recommended)
                            .id(SidebarSelection.recommended)
                        Label("Themes", systemImage: "paintpalette")
                            .tag(SidebarSelection.themes)
                            .id(SidebarSelection.themes)
                    }
                    // Options — the option categories in newcomer-frequency order (A3).
                    // Status is reserved for environment and maintenance summaries below.
                    Section("Options") {
                        ForEach(model.categories, id: \.self) { category in
                            Label(category, systemImage: Self.icon(for: category))
                                .tag(SidebarSelection.category(category))
                                .id(SidebarSelection.category(category))
                        }
                    }
                }
                .onChange(of: model.selection) { _, selection in
                    guard let selection else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(selection) }
                }
            }
            Divider()
            statusFooter
        }
        .navigationTitle("Ghostty")
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    }

    /// Aggregate status pinned to a fixed, non-scrolling footer (the Finder/Xcode idiom):
    /// its visibility never depends on how many category rows fit above it at any window
    /// height. It's a second single-row `List` sharing the same selection binding, so it
    /// gets the native sidebar highlight for free. Its icon reports aggregate health while
    /// Customized remains neutral: a changed value is not an error.
    private var statusFooter: some View {
        let needsAttention = model.statusNeedsAttention
        return List(selection: sidebarSelection) {
            HStack(spacing: DesignTokens.Spacing.standard) {
                Text("Status")
                Spacer(minLength: 0)
                Image(systemName: needsAttention
                      ? "exclamationmark.triangle.fill"
                      : "checkmark.circle.fill")
                    .foregroundStyle(needsAttention ? Color.orange : Color.green)
                    .accessibilityHidden(true)
            }
                .tag(SidebarSelection.status)
                .accessibilityLabel("Status")
                .accessibilityValue(needsAttention ? "Needs attention" : "All clear")
                .help(needsAttention ? "Status needs attention" : "Status is healthy")
        }
        .scrollDisabled(true)
        .frame(height: 44)
        .listStyle(.sidebar)
    }

    static func icon(for category: String) -> String {
        switch category {
        // Distinct from the Themes row's `paintpalette` above, so the two adjacent
        // color-ish entries don't read as the same icon.
        case "Appearance": return "paintbrush"
        case "Font & Text": return "textformat"
        case "Window": return "macwindow"
        case "Tabs & Splits": return "rectangle.split.2x1"
        case "Cursor": return "cursorarrow"
        case "Mouse & Scrolling": return "computermouse"
        case OptionCategorizer.keybindingsCategory: return "keyboard"
        case "Clipboard": return "doc.on.clipboard"
        case "Notifications & Bell": return "bell"
        case "Startup & Shell": return "terminal"
        case "macOS": return "apple.logo"
        case OptionCategorizer.advancedCategory: return "gearshape.2"
        default: return "gearshape"
        }
    }
}
