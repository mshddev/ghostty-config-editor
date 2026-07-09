import SwiftUI
import AppKit
import GhosttyConfigKit

/// The in-window Status hub. It keeps infrequent environment and maintenance state out
/// of the primary editing navigation while preserving one place to inspect Ghostty,
/// Customized values, and Problems.
///
/// Laid out **health-first** in three grouped cards (G-2): **Health** (Problems +
/// Customized as prominent tiles up top, so "is anything wrong?" reads first),
/// **Environment** (the Ghostty binary, the config file, and the auto-reload behavior —
/// where things live and how saving behaves), and **Manage** (backup + reset). This
/// collapses the former seven flat sections into three denser groups. Config-missing has
/// a single home in Environment's Config file row (it no longer also shows under
/// Problems). Reads the shared `AppModel` from the environment.
struct StatusView: View {
    @Environment(AppModel.self) private var model
    let ghosttyVersion: String
    @State private var confirmingReset = false

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader(title: "Status")
            Divider()
            Form {
                healthSection
                environmentSection
                manageSection
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
            Button("Reset \(model.resettableCount) Setting\(model.resettableCount == 1 ? "" : "s")", role: .destructive) {
                Task { await model.resetAllCustomized() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every option you've customized returns to its default. Your current config is backed up first, and you can undo this with ⌘Z.")
        }
    }

    // MARK: - Health (G-2) — Problems + Customized, up top, 2-up

    /// Health leads the surface: the two things you'd want to know at a glance, rendered
    /// as free-standing tiles (cleared row chrome) side by side. Problems carries health
    /// color (green / orange); Customized stays neutral — a changed value isn't an error.
    @ViewBuilder
    private var healthSection: some View {
        Section("Health") {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.cozy) {
                problemsTile
                customizedTile
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var problemsTile: some View {
        if model.configMissing {
            // Config-missing is flagged (and fixable) in Environment › Config file; the
            // Problems tile stays about validity so the two don't duplicate that state.
            StatusHealthTile(systemImage: "checkmark.circle.fill", tint: .green,
                             label: "Problems", value: "None")
        } else if model.lintReport == nil {
            StatusHealthTile(systemImage: "ellipsis.circle", tint: .secondary,
                             label: "Problems", value: "Checking…")
        } else if model.problemCount > 0 {
            let count = model.problemCount
            StatusHealthTile(systemImage: "exclamationmark.triangle.fill", tint: .orange,
                             label: "Problems", value: "\(count) found",
                             actionTitle: "Review", action: { model.setStatusDestination(.problems) })
        } else {
            StatusHealthTile(systemImage: "checkmark.circle.fill", tint: .green,
                             label: "Problems", value: "None")
        }
    }

    @ViewBuilder
    private var customizedTile: some View {
        if model.customizedCount == 0 {
            StatusHealthTile(systemImage: "slider.horizontal.3", tint: .secondary,
                             label: "Customized", value: "None")
        } else {
            let count = model.customizedCount
            StatusHealthTile(systemImage: "slider.horizontal.3", tint: .secondary,
                             label: "Customized", value: "\(count) option\(count == 1 ? "" : "s")",
                             actionTitle: "Review", action: { model.setStatusDestination(.customized) })
        }
    }

    // MARK: - Environment (G-2) — binary, config file, auto-reload behavior

    @ViewBuilder
    private var environmentSection: some View {
        @Bindable var model = model
        Section("Environment") {
            ghosttyRow
            configFileRow
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                Toggle("Automatically reload Ghostty after changes", isOn: $model.autoReloadEnabled)
                Text("After each saved change, the app asks the running Ghostty to reload its config so live terminals update right away. Uses Ghostty's reload signal — needs Ghostty 1.2 or newer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The Ghostty binary: version + health glyph, with Choose… (and an escape back to
    /// auto-detected when a manual binary is in force). (FEATURES-2)
    private var ghosttyRow: some View {
        let detected = model.resolvedBinaryPath != nil
        return HStack(spacing: DesignTokens.Spacing.cozy) {
            healthGlyph(detected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: detected ? .green : .orange,
                        label: detected ? "Detected" : "Needs attention")
            VStack(alignment: .leading, spacing: 1) {
                Text(detected
                     ? (ghosttyVersion.isEmpty ? "Ghostty" : "Ghostty \(ghosttyVersion)")
                     : "Ghostty not detected")
                Text(model.binaryOverride != nil
                     ? "Using a binary you chose manually."
                     : (detected ? "Detected automatically." : "Set the path to your Ghostty binary."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.Spacing.snug)
            Button("Choose…") { chooseBinary() }
            if model.binaryOverride != nil {
                Button("Use auto-detected") { Task { await model.setBinaryOverride(nil) } }
            }
        }
    }

    /// The config file: its resolved path + health glyph, with reveal, and create when
    /// it's missing (config-missing's single home now). (FEATURES-3)
    private var configFileRow: some View {
        HStack(spacing: DesignTokens.Spacing.cozy) {
            healthGlyph(model.configMissing ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                        tint: model.configMissing ? .orange : .green,
                        label: model.configMissing ? "Needs attention" : "Detected")
            VStack(alignment: .leading, spacing: 1) {
                Text("Config file")
                if let path = model.configFilePath { pathText(path) }
                if model.configMissing {
                    Text("No file yet — create it, or your first change will.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DesignTokens.Spacing.snug)
            Button("Reveal in Finder") { model.revealConfigInFinder() }
            if model.configMissing {
                Button("Create") { Task { await model.createConfigFileIfMissing() } }
            }
        }
    }

    // MARK: - Manage (G-2) — backup + reset

    /// Backup actions and the destructive reset, merged. Reset renders red via
    /// DestructiveRowButton (a grouped Form drops `role:`-only styling, DS-7) and only
    /// appears when there's something to reset.
    @ViewBuilder
    private var manageSection: some View {
        Section("Manage") {
            LabeledContent {
                HStack(spacing: DesignTokens.Spacing.snug) {
                    Button("Copy") { model.copyConfigToPasteboard() }
                    Button("Export…") {
                        if let text = model.primaryConfigText { ConfigTransfer.export(text) }
                    }
                    Button("Import…") {
                        if let text = ConfigTransfer.chooseImportText() {
                            Task { await model.importConfig(text: text) }
                        }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Backup")
                    Text("Copy, export, or import your config.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if model.resettableCount > 0 {
                DestructiveRowButton(title: "Reset All to Defaults…") { confirmingReset = true }
            }
        }
    }

    // MARK: - Shared bits

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

    private func healthGlyph(_ systemImage: String, tint: Color, label: String) -> some View {
        Image(systemName: systemImage)
            .foregroundStyle(tint)
            .accessibilityLabel(label)
    }

    /// Choose the Ghostty binary and apply it. Persists through `setBinaryOverride`,
    /// which re-discovers the environment immediately.
    private func chooseBinary() {
        guard let chosen = BinaryChooser.choose() else { return }
        Task { await model.setBinaryOverride(chosen) }
    }
}

/// One compact health tile (G-2 Grouped cards). A labeled value with an optional review
/// action, sized to sit 2-up. Health tiles carry health color; Customized stays neutral.
private struct StatusHealthTile: View {
    let systemImage: String
    let tint: Color
    let label: String
    let value: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.cozy) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold))
            }
            Spacer(minLength: DesignTokens.Spacing.snug)
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.caption)
            }
        }
        .padding(DesignTokens.Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.subtleFill, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }
}

/// Import/export of the whole config, shared by the Status pane and the File menu (G4).
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

/// A native file chooser for the Ghostty binary, shared by the Status pane and the
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
