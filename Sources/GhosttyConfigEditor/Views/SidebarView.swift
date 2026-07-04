import SwiftUI
import GhosttyConfigKit

/// The leading column: three labeled sections — **Get started**, **Settings**, and
/// **Status** — so every destination lives in the sidebar with a coherent "you are
/// here" (R6, D1). Customized and Problems are real tagged rows now (they used to be
/// top-bar buttons that left the sidebar with nothing selected — the lost-selection
/// bug); the config-health badge that lived in the toolbar moves onto the Problems row.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            // Get started — the exploratory surfaces a newcomer opens first. Recommended
            // is pinned at the top (the curated "start here" set, F1); the app still
            // *launches* on Themes to preserve its identity (Open Question #2).
            Section("Get started") {
                Label("Recommended", systemImage: "sparkles")
                    .tag(SidebarSelection.recommended)
                Label("Themes", systemImage: "paintpalette")
                    .tag(SidebarSelection.themes)
            }
            // Settings — the renamed option categories, in newcomer-frequency order (A3).
            Section("Settings") {
                ForEach(model.categories, id: \.self) { category in
                    Label(category, systemImage: Self.icon(for: category))
                        .tag(SidebarSelection.category(category))
                }
            }
            // Status — what you changed, and what's wrong. Tagged rows, so the sidebar
            // stays highlighted on these surfaces instead of clearing its selection.
            Section("Status") {
                Label("Customized", systemImage: "slider.horizontal.3")
                    .tag(SidebarSelection.customized)
                // `.tag` must be the outermost modifier for List selection to pick it
                // up — with `.badge` applied *after* the tag, clicking this row silently
                // failed to select it (caught in live testing). Badge first, tag last.
                Label("Problems", systemImage: "checklist")
                    .badge(problemsBadge)
                    .tag(SidebarSelection.problems)
                // App settings, in-window now (G1): binary path, config-file location,
                // auto-reload. ⌘, selects this too. The gear icon distinguishes it from
                // the "Settings" *section* header above (which groups option categories).
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarSelection.settings)
            }
        }
        .navigationTitle("Ghostty")
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    }

    /// The config-health badge on the Problems row — the status the toolbar's health
    /// chip used to carry (C4), now folded into the sidebar (D1). Shows the actionable
    /// problem count when there are any, the first-launch "No config" cue when no file
    /// exists yet, and nothing when the config is clean.
    private var problemsBadge: Text? {
        if model.configMissing { return Text("No config") }
        let count = model.problemCount
        return count > 0 ? Text("\(count)") : nil
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
