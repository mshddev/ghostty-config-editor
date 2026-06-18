import SwiftUI
import GhosttyConfigKit

/// The leading column: discovery shortcuts plus option categories (R3, R6).
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Discover") {
                Label("Customized", systemImage: "pencil")
                    .tag(SidebarSelection.customized)
            }
            Section("Appearance") {
                Label("Themes", systemImage: "paintpalette")
                    .tag(SidebarSelection.themes)
            }
            Section("Categories") {
                ForEach(model.categories, id: \.self) { category in
                    Label(category, systemImage: Self.icon(for: category))
                        .tag(SidebarSelection.category(category))
                }
            }
        }
        .navigationTitle("Ghostty")
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    }

    static func icon(for category: String) -> String {
        switch category {
        case "Font": return "textformat"
        case "Colors & Theme": return "paintpalette"
        case "Cursor": return "cursorarrow"
        case "Mouse": return "computermouse"
        case "Window": return "macwindow"
        case "Tabs & Splits": return "rectangle.split.2x1"
        case "Clipboard": return "doc.on.clipboard"
        case "Keybindings": return "keyboard"
        case "Shell Integration": return "terminal"
        case "Terminal": return "apple.terminal"
        case "macOS": return "apple.logo"
        case "Linux / GTK": return "shippingbox"
        default: return "gearshape"
        }
    }
}
