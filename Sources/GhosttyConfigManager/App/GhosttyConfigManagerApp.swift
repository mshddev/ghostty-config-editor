import SwiftUI
import AppKit
import GhosttyConfigKit

/// Without an `.app` bundle (e.g. when launched via `swift run`), macOS treats
/// the process as a background agent and never shows a window. Promote it to a
/// regular foreground app and bring it to the front. Inside a real bundle this
/// is a harmless no-op.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct GhosttyConfigManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.bootstrap() }
        }
        .windowStyle(.titleBar)
    }
}

/// Top-level shell. Until Ghostty is located it shows a status view; once ready
/// it presents the three-column Explorer (sidebar · option list · detail).
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.environmentState {
        case .loading:
            statusView(ProgressView("Locating Ghostty…"))
        case .notFound:
            statusView(ContentUnavailableView {
                Label("Ghostty not found", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Install Ghostty, or set the binary path, then reopen.\nSearched the app bundle, Homebrew, and your login shell.")
            })
        case .unsupported(let detail):
            statusView(ContentUnavailableView {
                Label("Couldn't verify Ghostty", systemImage: "questionmark.diamond")
            } description: {
                Text(detail)
            })
        case .ready(let environment):
            // Ghostty is located; now reflect catalog/config loading so a load
            // failure surfaces instead of an empty browser (it was previously
            // tracked in contentState but never rendered).
            switch model.contentState {
            case .failed(let detail):
                statusView(ContentUnavailableView {
                    Label("Couldn't load options", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Ghostty was found, but reading its option catalog failed.\n\(detail)")
                })
            case .idle, .loading:
                statusView(ProgressView("Loading options…"))
            case .loaded:
                browser(environment)
            }
        }
    }

    private func statusView(_ content: some View) -> some View {
        content.frame(minWidth: 900, minHeight: 560)
    }

    private func browser(_ environment: GhosttyEnvironment) -> some View {
        NavigationSplitView {
            SidebarView()
        } content: {
            switch model.selection {
            case .problems: ProblemsView()
            case .themes: ThemeBrowserView()
            default: OptionListView()
            }
        } detail: {
            switch model.selection {
            case .problems:
                ContentUnavailableView("Config health",
                                       systemImage: "stethoscope",
                                       description: Text("Validation runs against your live config via `ghostty +validate-config`."))
            case .themes:
                ContentUnavailableView("Pick a theme",
                                       systemImage: "paintpalette",
                                       description: Text("Click a theme to apply it. Previews are read from each theme's file."))
            default:
                OptionDetailView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                statusChip(environment)
            }
        }
    }

    @ViewBuilder
    private func statusChip(_ environment: GhosttyEnvironment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            Text("Ghostty \(environment.version)")
            if model.configMissing {
                Text("· no config file yet").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}
