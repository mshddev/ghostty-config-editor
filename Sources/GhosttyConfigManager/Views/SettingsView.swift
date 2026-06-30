import SwiftUI
import GhosttyConfigKit

/// The app's Preferences window (⌘,), hosting the auto-reload toggle (U3, R7).
///
/// Reads the shared `AppModel` from the environment — the `Settings` scene injects it
/// explicitly because SwiftUI does **not** propagate `.environment` across scenes
/// (KTD7). The toggle binds straight to `AppModel.autoReloadEnabled` (a stored,
/// persisted property), *not* a bare `@AppStorage`, so flipping it mid-session updates
/// the live model immediately rather than only on the next launch.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Automatically reload Ghostty after changes", isOn: $model.autoReloadEnabled)
                Text("After each saved change, the app asks the running Ghostty to reload its config so live terminals update right away. Uses Ghostty's reload signal — needs Ghostty 1.2 or newer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
