import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GhosttyConfigKit

/// The in-window Status hub. It keeps infrequent environment and maintenance state out
/// of the primary editing navigation while preserving one place to inspect Ghostty,
/// Customized values, and Problems.
///
/// Laid out **health-first** in three grouped cards: **Health** (Problems +
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
    @State private var confirmingRename = false
    /// Whether this bundle is the LaunchServices default editor for `.ghostty` —
    /// read on appear and after registering (NSWorkspace state isn't observable).
    @State private var isDefaultEditor = false
    @State private var registrationError: String?

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
            // (Saved · Undo / error + Reload) shows in the same bar as every surface.
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

    // MARK: - Health — Problems + Customized, up top, 2-up

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

    // MARK: - Environment — binary, config file, auto-reload behavior

    @ViewBuilder
    private var environmentSection: some View {
        @Bindable var model = model
        Section("Environment") {
            ghosttyRow
            configFileRow
            ghosttyIntegrationRow
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
    /// auto-detected when a manual binary is in force).
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
    /// it's missing (config-missing's single home now).
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

    /// Ghostty ⌘, integration. Ghostty (≥ 1.3) opens its config with the
    /// LaunchServices default editor for the file's *extension*, so landing its
    /// Open Config command here takes two independently-completable steps, each
    /// with its own row state: the config must carry the `.ghostty` name (legacy
    /// extension-less files get a rename offer), and this app must be the default
    /// editor for `.ghostty` (a one-click registration). Hidden outside a packaged
    /// `.app` — `swift run` yields a bare executable LaunchServices can't register.
    @ViewBuilder
    private var ghosttyIntegrationRow: some View {
        if DefaultEditorRegistration.isCapable {
            HStack(spacing: DesignTokens.Spacing.cozy) {
                if let offer = model.configRenameOffer {
                    healthGlyph("circle.dashed", tint: .secondary, label: "Not set up")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Open from Ghostty (⌘,)")
                        Text("Ghostty opens its config in the editor assigned to .ghostty files. Rename \(fileName(offer.from)) to \(fileName(offer.to)) to enable that here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DesignTokens.Spacing.snug)
                    Button("Rename…") { confirmingRename = true }
                } else if primaryHasGhosttyExtension {
                    if isDefaultEditor {
                        healthGlyph("checkmark.circle.fill", tint: .green, label: "Ready")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Open from Ghostty (⌘,)")
                            Text("Ghostty's Open Config command opens this app.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: DesignTokens.Spacing.snug)
                    } else {
                        healthGlyph("circle.dashed", tint: .secondary, label: "Not set up")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Open from Ghostty (⌘,)")
                            Text("Ghostty opens its config in the editor assigned to .ghostty files. Make that this app, and ⌘, in Ghostty lands here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let registrationError {
                                Text(registrationError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: DesignTokens.Spacing.snug)
                        Button("Use This App") { registerAsDefaultEditor() }
                    }
                }
            }
            .task { isDefaultEditor = DefaultEditorRegistration.isCurrentDefault }
            .confirmationDialog(
                "Rename config to config.ghostty?",
                isPresented: $confirmingRename, titleVisibility: .visible
            ) {
                Button("Rename") { Task { await model.renameLegacyConfig() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Same file, same contents — only the name changes, and Ghostty (1.3 or newer) keeps reading it. If scripts or dotfiles reference the old path by name, update them afterwards.")
            }
        }
    }

    /// True when the primary config (existing or first-write target) already
    /// carries the `.ghostty` extension Ghostty's editor lookup keys on.
    private var primaryHasGhosttyExtension: Bool {
        guard let path = model.configFilePath else { return false }
        return (path as NSString).pathExtension == "ghostty"
    }

    private func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Register this bundle as the default `.ghostty` editor, then re-read the
    /// LaunchServices state so the row flips to Ready (or surfaces the failure).
    private func registerAsDefaultEditor() {
        Task {
            do {
                try await DefaultEditorRegistration.makeDefault()
                registrationError = nil
            } catch {
                registrationError = "Couldn't set the default editor: \(error.localizedDescription)"
            }
            isDefaultEditor = DefaultEditorRegistration.isCurrentDefault
        }
    }

    // MARK: - Manage — backup + reset

    /// Backup actions and the destructive reset, merged. Reset renders red via
    /// DestructiveRowButton (a grouped Form drops `role:`-only styling) and only
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

/// One compact health tile. A labeled value with an optional review
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

/// Import/export of the whole config, shared by the Status pane and the File menu.
/// Export writes the current bytes to a chosen file; import reads a file, confirms the
/// replace (the write engine backs up the current config first and the import is
/// undoable), and returns the text for `AppModel.importConfig` to validate + commit.
///
/// `@MainActor` because these drive AppKit panels/alerts, which are main-actor-isolated;
/// every caller is a SwiftUI menu or view action, so it is already on the main actor.
@MainActor
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

/// LaunchServices state + registration for the `.ghostty` extension — the piece
/// that makes Ghostty's ⌘, land in this app. Ghostty (≥ 1.3) resolves which
/// editor opens its config via the default application for the file's extension;
/// the packaged Info.plist (`scripts/package-app.sh`) declares the UTI and the
/// Editor claim, and this sets or inspects the user's default-handler choice.
///
/// `@MainActor` because its only callers are SwiftUI view actions, matching the
/// other AppKit-facing helpers in this file.
@MainActor
enum DefaultEditorRegistration {
    /// The type LaunchServices resolves for the `.ghostty` extension — this
    /// app's exported declaration once the bundle is registered, or a dynamic
    /// type before that. Either way it is the type Ghostty's lookup resolves.
    private static var ghosttyType: UTType? { UTType(filenameExtension: "ghostty") }

    /// True when running from a packaged `.app` — the only form LaunchServices
    /// can register as a handler. `swift run` yields a bare executable, so the
    /// Status row hides instead of offering a registration that must fail.
    static var isCapable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// True when this bundle is already the default editor for `.ghostty`.
    static var isCurrentDefault: Bool {
        guard let type = ghosttyType,
              let current = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return current.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path
    }

    /// Make this bundle the LaunchServices default editor for `.ghostty` files.
    static func makeDefault() async throws {
        guard let type = ghosttyType else { return }
        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
    }
}

/// A native file chooser for the Ghostty binary, shared by the Status pane and the
/// not-found/unsupported recovery screens. If the user picks `Ghostty.app`, it
/// resolves to the inner CLI binary the locator actually probes (`BinaryLocator` wants
/// an executable, not the bundle).
///
/// `@MainActor` because it drives an AppKit open panel, which is main-actor-isolated;
/// every caller is a SwiftUI menu or view action, so it is already on the main actor.
@MainActor
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
