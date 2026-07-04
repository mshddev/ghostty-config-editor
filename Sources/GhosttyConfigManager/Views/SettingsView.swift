import SwiftUI
import AppKit
import GhosttyConfigKit

/// The in-window app-settings surface (G1). Replaces the removed near-empty ⌘,
/// Preferences *window* — ⌘, now selects this pane in the sidebar (see
/// `GhosttyConfigManagerApp`), cohering with the single-window model (G6).
///
/// Closes the "the not-found screen says set the binary path, but no UI sets it"
/// dead-end (FEATURES-2/3, ONBOARD-2/8/12): a **Ghostty** section chooses the binary
/// (persisted via `BinaryOverrideStore`, so a fix survives relaunch), a **Config file**
/// section reveals/creates the file, and **Behavior** carries the auto-reload toggle.
/// Reads the shared `AppModel` from the environment (which the WindowGroup injects — no
/// more cross-scene injection, since the separate `Settings` scene is gone).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            SurfaceHeader(title: "Settings")
            Divider()
            Form {
                ghosttySection
                configFileSection
                Section("Behavior") {
                    Toggle("Automatically reload Ghostty after changes", isOn: $model.autoReloadEnabled)
                    Text("After each saved change, the app asks the running Ghostty to reload its config so live terminals update right away. Uses Ghostty's reload signal — needs Ghostty 1.2 or newer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - Ghostty binary (FEATURES-2)

    @ViewBuilder
    private var ghosttySection: some View {
        Section("Ghostty") {
            if let path = model.resolvedBinaryPath {
                LabeledContent("Binary") {
                    pathText(path)
                }
            } else {
                Label("Ghostty wasn't found automatically.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.binaryOverride != nil {
                Text("Using a binary you chose manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose…") { chooseBinary() }
                if model.binaryOverride != nil {
                    Button("Use auto-detected") { Task { await model.setBinaryOverride(nil) } }
                }
            }
        }
    }

    // MARK: - Config file (FEATURES-3)

    @ViewBuilder
    private var configFileSection: some View {
        Section("Config file") {
            if let path = model.configFilePath {
                LabeledContent("Location") {
                    pathText(path)
                }
            }
            if model.configMissing {
                Text("No file yet — your first change creates it, or create it now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Reveal in Finder") { model.revealConfigInFinder() }
                if model.configMissing {
                    Button("Create config file") { Task { await model.createConfigFileIfMissing() } }
                }
            }
        }
    }

    /// A resolved filesystem path rendered compactly (monospaced, middle-truncated,
    /// selectable) so a long `~/.config/...` path never blows out the row.
    private func pathText(_ path: String) -> some View {
        Text(path)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    /// Choose the Ghostty binary and apply it. Persists through `setBinaryOverride`,
    /// which re-discovers the environment immediately.
    private func chooseBinary() {
        guard let chosen = BinaryChooser.choose() else { return }
        Task { await model.setBinaryOverride(chosen) }
    }
}

/// A native file chooser for the Ghostty binary, shared by the Settings pane and the
/// not-found/unsupported recovery screens (G1). If the user picks `Ghostty.app`, it
/// resolves to the inner CLI binary the locator actually probes (`BinaryLocator` wants
/// an executable, not the bundle).
enum BinaryChooser {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose the Ghostty binary"
        panel.message = "Select the Ghostty app or its command-line binary."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        var chosen = url.path
        if chosen.hasSuffix(".app") { chosen += "/Contents/MacOS/ghostty" }
        return chosen
    }
}
