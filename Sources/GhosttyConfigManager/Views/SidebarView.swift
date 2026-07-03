import SwiftUI
import GhosttyConfigKit

/// The leading column: a flat list of Themes plus the option categories (R3, R6).
/// The "Customized" discovery shortcut now lives in the top bar, not here.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Label("Themes", systemImage: "paintpalette")
                .tag(SidebarSelection.themes)
            ForEach(model.categories, id: \.self) { category in
                Label(category, systemImage: Self.icon(for: category))
                    .tag(SidebarSelection.category(category))
            }
        }
        .navigationTitle("Ghostty")
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    }

    static func icon(for category: String) -> String {
        switch category {
        case "Appearance": return "paintpalette"
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
