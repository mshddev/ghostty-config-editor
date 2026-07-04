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
    @State private var confirmingReset = false

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
                backupSection
            }
            .formStyle(.grouped)
            // Import / reset route through the shared write engine, so their outcome
            // (Saved · Undo / error + Reload) shows in the same bar as every surface (G4).
            SurfaceFeedbackBar(applyState: model.applyState)
        }
        .confirmationDialog(
            "Reset all settings to their defaults?",
            isPresented: $confirmingReset, titleVisibility: .visible
        ) {
            Button("Reset \(model.customizedCount) Setting\(model.customizedCount == 1 ? "" : "s")", role: .destructive) {
                Task { await model.resetAllCustomized() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every option you've customized returns to its default. Your current config is backed up first, and you can undo this with ⌘Z.")
        }
    }

    // MARK: - Backup & reset (G4)

    @ViewBuilder
    private var backupSection: some View {
        Section("Backup & reset") {
            Button("Copy Full Config") { model.copyConfigToPasteboard() }
            Button("Export…") {
                if let text = model.primaryConfigText { ConfigTransfer.export(text) }
            }
            Button("Import…") {
                if let text = ConfigTransfer.chooseImportText() {
                    Task { await model.importConfig(text: text) }
                }
            }
            if model.customizedCount > 0 {
                Button("Reset All to Defaults…", role: .destructive) { confirmingReset = true }
            }
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

/// Import/export of the whole config, shared by the Settings pane and the File menu (G4).
/// Export writes the current bytes to a chosen file; import reads a file, confirms the
/// replace (the write engine backs up the current config first and the import is
/// undoable), and returns the text for `AppModel.importConfig` to validate + commit.
enum ConfigTransfer {
    static func export(_ text: String) {
        let panel = NSSavePanel()
        panel.title = "Export Ghostty config"
        panel.nameFieldStringValue = "ghostty-config.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Present an open panel, then a replace confirmation, returning the imported text
    /// (or nil if cancelled / unreadable). Import replaces-with-backup, so the confirm
    /// alert says exactly that.
    static func chooseImportText() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Import Ghostty config"
        panel.message = "Choose a config file to replace your current one."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let alert = NSAlert()
        alert.messageText = "Replace your Ghostty config?"
        alert.informativeText = "This replaces your current config with the imported file. Your current config is backed up first, and you can undo this with ⌘Z."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? text : nil
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
