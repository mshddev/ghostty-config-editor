import SwiftUI
import GhosttyConfigKit

/// The leading column: three labeled sections — **Get started**, **Settings**, and
/// **Status** — so every destination lives in the sidebar with a coherent "you are
/// here" (R6, D1). Customized and Problems are real tagged rows now (they used to be
/// top-bar buttons that left the sidebar with nothing selected — the lost-selection
/// bug); the config-health badge that lived in the toolbar moves onto the Problems row.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    /// The sidebar's selection reads as **nil while a global Find is in progress** (IA-3),
    /// so no category stays falsely highlighted when the detail pane is showing Find
    /// results instead. Writing through ends Find on *any* pick and navigates: the setter
    /// calls `endFind()` explicitly rather than relying on the app's `onChange(selection)`,
    /// because re-picking the row Find was started from writes an **equal** selection —
    /// which `onChange` wouldn't fire, leaving the click dead. When Find ends, the previous
    /// highlight returns. Both the scrolling List and the footer bind through this, so the
    /// footer's "Settings" row also clears during Find.
    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(get: { model.isFinding ? nil : model.selection },
                set: { newValue in
                    if model.isFinding { model.endFind() }
                    model.selection = newValue
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            // The scrolling destinations. Wrapped in a ScrollViewReader so selecting a row
            // that's off-screen at a short window height (Problems at 520pt) scrolls it into
            // view instead of leaving it hidden below the fold (IA-1). Each row carries an
            // `.id` matching its selection so `scrollTo` can target it.
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
                    // Options — the renamed option categories, in newcomer-frequency order
                    // (A3). Named "Options" (was "Settings") so the word points at exactly
                    // one destination — the app-settings row below is the only "Settings" (IA-2).
                    Section("Options") {
                        ForEach(model.categories, id: \.self) { category in
                            Label(category, systemImage: Self.icon(for: category))
                                .tag(SidebarSelection.category(category))
                                .id(SidebarSelection.category(category))
                        }
                    }
                    // Status — what you changed, and what's wrong. Tagged rows, so the
                    // sidebar stays highlighted on these surfaces instead of clearing.
                    Section("Status") {
                        Label("Customized", systemImage: "slider.horizontal.3")
                            // `.tag`/`.id` must stay outermost for List selection to pick
                            // them up — a `.badge` applied *after* the tag silently broke
                            // selection (caught in live testing). Badge first, tag/id last.
                            .badge(customizedBadge)
                            .tag(SidebarSelection.customized)
                            .id(SidebarSelection.customized)
                        Label("Problems", systemImage: "checklist")
                            .badge(problemsBadge)
                            .tag(SidebarSelection.problems)
                            .id(SidebarSelection.problems)
                    }
                }
                .onChange(of: model.selection) { _, selection in
                    guard let selection else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(selection) }
                }
            }
            Divider()
            settingsFooter
        }
        .navigationTitle("Ghostty")
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    }

    /// App settings pinned to a fixed, non-scrolling footer (the Finder/Xcode idiom, IA-1):
    /// its visibility never depends on how many category rows fit above it at any window
    /// height. It's a second single-row `List` sharing the same selection binding, so it
    /// gets the native sidebar highlight for free and lights up only when Settings is the
    /// active destination. ⌘, selects it too; the gear icon separates it from the "Options"
    /// section that groups the categories.
    private var settingsFooter: some View {
        List(selection: sidebarSelection) {
            Label("Settings", systemImage: "gearshape")
                .tag(SidebarSelection.settings)
        }
        .scrollDisabled(true)
        .frame(height: 44)
        .listStyle(.sidebar)
    }

    /// The count badge on the Customized row (IA-9) — how many options deviate from the
    /// defaults, so the sidebar advertises whether there's anything to review without a
    /// click. Nil (no badge) when nothing is customized.
    private var customizedBadge: Text? {
        let count = model.customizedCount
        return count > 0 ? Text("\(count)") : nil
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
