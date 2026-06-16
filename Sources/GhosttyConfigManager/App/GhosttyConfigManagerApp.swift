import SwiftUI
import GhosttyConfigKit

@main
struct GhosttyConfigManagerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 800, minHeight: 500)
                .task { await model.bootstrap() }
        }
        .windowStyle(.titleBar)
    }
}

/// The top-level NavigationSplitView shell (U1 skeleton). Later units fill the
/// sidebar with option categories and the detail pane with option detail.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            List {
                Section("Ghostty") {
                    environmentRow
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            placeholderDetail
        }
        .navigationTitle("Ghostty Config Manager")
    }

    @ViewBuilder
    private var environmentRow: some View {
        switch model.environmentState {
        case .loading:
            Label("Locating Ghostty…", systemImage: "hourglass")
        case .ready(let env):
            Label("Ghostty \(env.version)", systemImage: "checkmark.seal")
        case .notFound:
            Label("Ghostty not found", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .unsupported(let detail):
            Label("Unsupported: \(detail)", systemImage: "questionmark.diamond")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var placeholderDetail: some View {
        switch model.environmentState {
        case .loading:
            ProgressView("Locating Ghostty…")
        case .ready(let env):
            ContentUnavailableView {
                Label("Ghostty \(env.version)", systemImage: "terminal")
            } description: {
                Text("Connected to \(env.binaryPath).\nThe option catalog will appear here.")
            }
        case .notFound:
            ContentUnavailableView {
                Label("Ghostty not found", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Install Ghostty, or set the binary path in settings, then reopen.")
            }
        case .unsupported(let detail):
            ContentUnavailableView {
                Label("Couldn't verify Ghostty", systemImage: "questionmark.diamond")
            } description: {
                Text(detail)
            }
        }
    }
}
