import SwiftUI
import AppKit
import Combine
import GhosttyConfigKit

/// Window sizing + content-width metrics kept in one place so the WindowGroup
/// frame, the status view, and the capped content column stay reconciled
/// (LAYOUT-1, LAYOUT-4, LAYOUT-14). Previously the minimum lived in two frames
/// and the default was a separate magic number.
enum WindowMetrics {
    /// Smallest the window may shrink to — the sidebar plus a still-usable detail column.
    static let minWidth: CGFloat = 660
    static let minHeight: CGFloat = 520
    /// First-launch size: deliberately snug (like System Settings) so label and value
    /// stay close. A wider window only inflates the gap between them, so we don't open big
    /// — just wide enough that the toolbar chips don't collapse into an overflow menu.
    /// Height only affects how much of the (scrollable) content shows, never the
    /// label↔value gap, so it's tall enough to fit the whole sidebar — Get started +
    /// Settings + Status — without Problems (which carries the health badge) landing
    /// under the fold at launch (D1).
    static let defaultWidth: CGFloat = 780
    static let defaultHeight: CGFloat = 660
    /// Hard ceiling on how wide the window may get (drag-resize; zoom is disabled).
    /// A settings utility has no use for a sprawling width — past here it's just void
    /// beside a centered column. Height is generous for long option forms.
    static let maxWidth: CGFloat = 900
    static let maxHeight: CGFloat = 1300
    /// The detail column caps here and centers, so a wide window never strands a
    /// gap between each option's label and its right-aligned control.
    static let contentMaxWidth: CGFloat = 640
}

/// Centers a surface in a fixed-width column (the System Settings idiom). Applied
/// once to `mainColumn` so every surface caps uniformly; below the cap the content
/// fills the column normally.
private struct CappedContentColumn: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: WindowMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private extension View {
    func cappedContentColumn() -> some View { modifier(CappedContentColumn()) }
}

/// Makes the window behave like macOS System Settings: no fullscreen, no zoom, and a
/// bounded maximum width. A config utility gains nothing from a maximized window — it
/// just floats a centered column in a void — so we take those affordances away rather
/// than manage the void. Reaches into the hosting `NSWindow` (SwiftUI exposes no
/// declarative API for the zoom button or fullscreen behavior).
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window isn't attached during makeNSView; defer to the next runloop turn.
        DispatchQueue.main.async { [weak view] in configure(view?.window) }
        return view
    }

    // Re-assert on updates too: the window may not be attached on the first runloop
    // turn, and AppKit re-validates the standard title-bar buttons on later layout
    // passes, so a one-shot in makeNSView could silently miss or be undone.
    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        // `.fullScreenNone` is mutually exclusive with the `.fullScreenPrimary` flag a
        // titleBar window carries by default; without removing that first, AppKit keeps
        // the combined set contradictory and ⌃⌘F / the Window menu can still fullscreen
        // the window — defeating the whole point of the change.
        window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.maxSize = NSSize(width: WindowMetrics.maxWidth, height: WindowMetrics.maxHeight)
        // Each surface titles itself in its in-content SurfaceHeader (C3), so the
        // title-bar text is redundant — and with the per-surface navigationTitle gone
        // it would otherwise fall back to the truncated app name.
        window.titleVisibility = .hidden
    }
}

/// One top-bar chip, so identity/health/Customized share a single shape (LAYOUT-6).
/// With an `action` it renders as a bordered, hover-highlighting button (so an
/// actionable chip *looks* actionable) with an optional trailing chevron; without
/// one it's a plain label (identity). The `tint` colors only the leading glyph, so a
/// health chip can carry a red/orange status icon without dyeing its whole label.
private struct ToolbarChip: View {
    var systemImage: String? = nil
    var tint: Color = .secondary
    let title: String
    var isActive: Bool = false
    var showsChevron: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) {
                chipContent
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isActive ? .isSelected : [])
        } else {
            content.foregroundStyle(.secondary)
        }
    }

    /// The actionable chip's own chrome. The label stays `.primary` — accent tints only
    /// the glyph (DS-6), so "on" doesn't read as a hyperlink. A hairline border is always
    /// present so it reads as clickable regardless of state, and an *active* chip fills
    /// with a subtle accent tint (not border-only) so the on-state survives focus loss
    /// instead of riding on accent alone (CB-10).
    private var chipContent: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.standard, style: .continuous)
        return content
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                ZStack {
                    shape.fill(isActive ? AnyShapeStyle(DesignTokens.accentFill) : AnyShapeStyle(Color.clear))
                    shape.strokeBorder(
                        isActive ? AnyShapeStyle(Color.accentColor.opacity(0.45)) : AnyShapeStyle(.quaternary),
                        lineWidth: 1)
                }
            }
            .contentShape(shape)
    }

    private var content: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(title)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
    }
}

/// A full-pane status/failure surface at pass-2 parity (GAP-6): the app's own icon as
/// the identity moment, a state glyph + surface-title, a plain-language message, and
/// recovery actions — so a not-found / unverified / load-failed screen looks like the
/// same product as the happy path, not a bare system empty-state. Tints come from the
/// caller (token-relative), so light mode stays legible (U25 re-checks).
private struct StatusScreen<Actions: View>: View {
    var stateIcon: String? = nil
    var stateTint: Color = .secondary
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 52, height: 52)
                .accessibilityHidden(true)
            if let stateIcon {
                Image(systemName: stateIcon)
                    .font(.system(size: 26))
                    .foregroundStyle(stateTint)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.surfaceTitle)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions().padding(.top, 2)
        }
        .frame(maxWidth: 420)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Without an `.app` bundle (e.g. when launched via `swift run`), macOS treats
/// the process as a background agent and never shows a window. Promote it to a
/// regular foreground app and bring it to the front. Inside a real bundle this
/// is a harmless no-op.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // A config utility has no use for fullscreen — maximizing just floats a
        // centered column in a void (see WindowConfigurator). Disabling it via
        // `NSWindow.collectionBehavior` doesn't stick under SwiftUI's window
        // management, so remove the "Enter Full Screen" menu command itself (which
        // also strips its ⌃⌘F key equivalent). Found by its action selector so it's
        // robust to localization. SwiftUI can rebuild the menu, so re-strip it every
        // time any menu begins tracking — that's the moment before it becomes clickable.
        Self.removeFullScreenMenuItem()
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in Self.removeFullScreenMenuItem() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private static func removeFullScreenMenuItem() {
        let selector = #selector(NSWindow.toggleFullScreen(_:))
        for submenu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
            for item in submenu.items where item.action == selector {
                submenu.removeItem(item)
            }
        }
    }
}

@main
struct GhosttyConfigEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    /// The current surface's "focus filter field" action, if it has a filter (U26). Drives
    /// the "Filter Current List" (⌘L) menu command; nil ⇒ the command disables.
    @FocusedValue(\.focusSurfaceFilter) private var focusSurfaceFilter

    var body: some Scene {
        // A single `Window`, not a `WindowGroup` (U35/GAP-5): this is a settings editor,
        // and two windows sharing one `AppModel` made `selection`/`query`/`applyState`
        // global — the windows interfered and could drive each other into stale-on-disk.
        // One window matches the mental model and makes `@SceneStorage` restoration (G2)
        // unambiguous (there's exactly one window's state to persist).
        Window(AppInfo.productName, id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: WindowMetrics.minWidth, minHeight: WindowMetrics.minHeight)
                .background(WindowConfigurator())   // no fullscreen/zoom, bounded max width
                // Bootstrap, then decide once whether to present the first-run welcome
                // (needs `configMissing`, known only after the config is read).
                .task { await model.bootstrap(); model.showWelcomeIfNeeded() }
        }
        .windowStyle(.titleBar)
        .commands {
            // Smart context-aware ⌘Z (G2): a focused text field's own undo wins (so
            // fixing a typo in the hex/search/value field undoes *that*, not the last
            // saved config write — the data-surprising footgun of blanket-replacing
            // `.undoRedo`); with no field-level undo, ⌘Z reverts the last applied write.
            // Redo only applies to the focused field (config-undo has no redo).
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { smartUndo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { smartRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            // Reload from disk (⌘R, G3) and Find (⌘F, D2) in the View menu, so both are
            // discoverable in the menu bar, not just via the toolbar/keyboard.
            CommandGroup(after: .sidebar) {
                Button("Reload from Disk") { Task { await model.reloadFromDisk() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Find…") { model.beginFind() }
                    .keyboardShortcut("f", modifiers: .command)
                // Jump keyboard focus into the current surface's filter field, when it has
                // one (U26): the per-surface search is otherwise only mouse-reachable.
                Button("Filter Current List") { focusSurfaceFilter?() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(focusSurfaceFilter == nil)
            }
            // Import / export / copy the whole config in the File menu (G4). Import is
            // replace-with-backup (confirmed + undoable); the model validates before writing.
            CommandGroup(replacing: .importExport) {
                Button("Copy Full Config") { model.copyConfigToPasteboard() }
                Button("Import Config…") {
                    if let text = ConfigTransfer.chooseImportText() {
                        Task { await model.importConfig(text: text) }
                    }
                }
                Button("Export Config…") {
                    if let text = model.primaryConfigText { ConfigTransfer.export(text) }
                }
            }
            // Re-open the first-run welcome any time (F2). Replaces the app's
            // (help-book-less) default Help menu with the one entry that's useful here.
            CommandGroup(replacing: .help) {
                Button(AppInfo.welcomeTitle) { model.openWelcome() }
            }
            // ⌘, still works, but there's no Preferences *window* anymore (G1/G6):
            // it selects the in-window Settings pane instead, preserving the macOS
            // muscle-memory affordance without a dead one-toggle window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.selection = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        // Options right-align their value control (the settings idiom), and a wider
        // window only inflates the gap between each label and its control — so the
        // window opens deliberately snug (like System Settings) and can't be zoomed or
        // fullscreened (see `WindowConfigurator`). First launch is centered on screen.
        .defaultSize(width: WindowMetrics.defaultWidth, height: WindowMetrics.defaultHeight)
        .defaultPosition(.center)
    }

    /// ⌘Z: prefer the focused text field's own undo (typo fixes in the hex / search /
    /// value fields), falling back to reverting the last applied config write. Checking
    /// the first responder first is what makes ⌘Z context-aware instead of a blanket
    /// hijack of every field's undo (G2).
    private func smartUndo() {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           let undoManager = textView.undoManager, undoManager.canUndo {
            undoManager.undo()
            return
        }
        Task { await model.undoLastApply() }  // guarded — a no-op when nothing is undoable
    }

    /// ⇧⌘Z: redo applies only to the focused text field — a reverted config write has no
    /// redo (re-applying it is a fresh edit).
    private func smartRedo() {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           let undoManager = textView.undoManager, undoManager.canRedo {
            undoManager.redo()
        }
    }
}

/// Top-level shell. Until Ghostty is located it shows a status view; once ready
/// it presents the two-column Explorer (sidebar · content). Options are edited
/// inline in the list, so there is no separate detail column.
struct RootView: View {
    @Environment(AppModel.self) private var model
    /// Honor Reduce Motion: transient in/out animations are dropped when it's on (H3).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Last-visited surface so the app reopens where you left off (G2). `@AppStorage`
    /// (UserDefaults), not `@SceneStorage`: with a single `Window` (G6) it's app-wide
    /// state, and unlike scene restoration it doesn't depend on the OS "close windows on
    /// quit" setting — so "reopen where you left off" is deterministic (KTD8 sanctions
    /// either; AppStorage is the reliable one here).
    @AppStorage("lastSelection") private var lastSelectionRaw = ""

    var body: some View {
        switch model.environmentState {
        case .loading:
            statusView(loadingScreen("Locating Ghostty…"))
        case .notFound:
            statusView(StatusScreen(
                stateIcon: "exclamationmark.triangle.fill", stateTint: .orange,
                title: "Ghostty not found",
                message: "Install Ghostty, or choose the binary yourself. Searched the app bundle, Homebrew, and your login shell."
            ) { recoveryButtons() })
        case .unsupported(let detail):
            statusView(StatusScreen(
                stateIcon: "questionmark.diamond.fill", stateTint: .orange,
                title: "Couldn't verify Ghostty",
                message: detail
            ) { recoveryButtons() })
        case .ready(let environment):
            // Ghostty is located; now reflect catalog/config loading so a load
            // failure surfaces instead of an empty browser (it was previously
            // tracked in contentState but never rendered).
            switch model.contentState {
            case .failed(let detail):
                statusView(StatusScreen(
                    stateIcon: "exclamationmark.triangle.fill", stateTint: .orange,
                    title: "Couldn't load options",
                    message: "Ghostty was found, but reading its option catalog failed.\n\(detail)"
                ) { recoveryButtons() })
            case .idle, .loading:
                statusView(loadingScreen("Loading options…"))
            case .loaded:
                browser(environment)
                    // The first-run welcome overlays the loaded app (F2), animating in/out.
                    .overlay {
                        if model.isShowingWelcome { WelcomeView() }
                    }
                    .animation(MotionSystem.gated(MotionSystem.settle, reduceMotion: reduceMotion), value: model.isShowingWelcome)
            }
        }
    }

    private func statusView(_ content: some View) -> some View {
        content.frame(minWidth: WindowMetrics.minWidth, minHeight: WindowMetrics.minHeight)
    }

    /// A loading pane that carries the app-icon identity moment (GAP-6), so even the
    /// transient "locating/loading" states read as this product rather than a bare spinner.
    private func loadingScreen(_ title: String) -> some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 52, height: 52)
                .accessibilityHidden(true)
            ProgressView(title)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Recovery actions on the not-found/unsupported/load-failed screens (G1): choose
    /// the Ghostty binary yourself (the dead-end the old copy pointed at with no UI) or
    /// retry discovery. "Choose Ghostty…" persists the pick and re-bootstraps.
    @ViewBuilder
    private func recoveryButtons() -> some View {
        HStack {
            Button("Choose Ghostty…") {
                if let path = BinaryChooser.choose() {
                    Task { await model.setBinaryOverride(path) }
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Try again") { Task { await model.bootstrap() } }
        }
    }

    /// The detail surface for the current selection, centered in a width-capped
    /// column (LAYOUT-1). The cap is applied here — once — so every surface
    /// (Options/Themes/Keybindings/Problems) caps uniformly rather than each view
    /// re-solving its own width.
    @ViewBuilder
    private var mainColumn: some View {
        Group {
            if model.isFinding {
                // Global Find (⌘F) overlays option results *regardless* of the current
                // surface (D2), so it replaces the detail column while active rather
                // than filtering whatever surface happens to be selected.
                GlobalFindView()
                    .transition(.opacity)
            } else {
                Group {
                    switch model.selection {
                    case .recommended: RecommendedView()
                    case .problems: ProblemsView()
                    case .themes: ThemeBrowserView()
                    case .settings: SettingsView()
                    case .category(let name) where name == OptionCategorizer.keybindingsCategory: KeybindEditorView()
                    default: OptionListView()
                    }
                }
                .transition(.opacity)
            }
        }
        // MO-8/CB-13: Find cross-fades, keyed to `isFinding` *only* — a plain category
        // switch (selection changes, isFinding stays false) opens no transaction, so
        // sidebar navigation stays instant. Gated on Reduce Motion via the one U2 helper.
        .animation(MotionSystem.gated(MotionSystem.quickFade, reduceMotion: reduceMotion),
                   value: model.isFinding)
        .cappedContentColumn()
        // Each surface titles itself in its in-content SurfaceHeader (C3); an explicit
        // empty title keeps the toolbar from falling back to the truncated app name.
        .navigationTitle("")
    }

    /// Every surface is now a self-contained two-column pane (sidebar · content).
    /// The option list edits each option inline, so the old third "detail" column
    /// — which only ever held one option's editor — is gone entirely.
    @ViewBuilder
    private func browser(_ environment: GhosttyEnvironment) -> some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                // A plain first-run explanation while no config exists yet (F2), above
                // whatever surface is showing. Disappears once the first change lands.
                if model.configMissing { FirstRunBanner() }
                mainColumn
            }
        }
        // Changing surface clears any lingering apply feedback so the next surface
        // (which may now show its own SurfaceFeedbackBar) doesn't inherit a stale
        // "Saved" from the previous one (C3), and dismisses the global Find overlay so
        // picking a sidebar row leaves Find (D2). Centralized here since every surface
        // can surface feedback now, not just the option list.
        // Restore the last-visited surface once, on first appearance of the browser
        // (G2). Guarded to the launch default so it only restores before the user
        // navigates — never overriding a live selection on a later layout pass.
        .onAppear {
            if model.selection == .themes,
               let restored = SidebarSelection(storageString: lastSelectionRaw) {
                model.selection = restored
            }
        }
        .onChange(of: model.selection) { _, newValue in
            model.resetApplyState()
            model.endFind()
            // Persist the surface for next launch (G2).
            if let newValue { lastSelectionRaw = newValue.storageString }
        }
        // On-activate re-sync (G3): coming back to the app after editing the config
        // externally ("Reveal in editor" invites exactly this) reloads from disk — but
        // only when the file actually changed and nothing is mid-apply, so it never
        // clobbers an in-app edit. The guard lives in the model; this only supplies the
        // AppKit focus signal.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.syncFromDiskIfChanged() }
        }
        .toolbar {
            // Identity ("which Ghostty") + the auto-reload status chip. Health and
            // Customized moved into the sidebar's Status section (D1); the top bar now
            // carries identity, at-a-glance auto-reload state, and Find.
            ToolbarItem(placement: .status) {
                identityChip(environment)
            }
            ToolbarItem(placement: .status) {
                autoReloadChip()
            }
            ToolbarItem(placement: .primaryAction) {
                findButton()
            }
        }
    }

    /// Global Find (⌘F): the second search tier (U20). Distinct from each surface's
    /// own local filter — it searches *all* options regardless of the current surface
    /// and opens a results overlay. Clickable (for pointer users) with a ⌘F equivalent.
    private func findButton() -> some View {
        // ⌘F lives on the View-menu Find command now (G2), so the shortcut isn't declared
        // twice; this stays a click affordance for pointer users. Routed through the
        // active-capable chip (U20/IA-3) so Find-mode is legible *in the chrome*: the chip
        // fills when a Find is in progress, and clicking it again ends Find. Toggle trait
        // for VoiceOver.
        ToolbarChip(
            systemImage: "magnifyingglass",
            tint: model.isFinding ? .accentColor : .secondary,
            title: "Find",
            isActive: model.isFinding,
            action: { model.isFinding ? model.endFind() : model.beginFind() }
        )
        .help("Find any setting (⌘F)")
        .accessibilityLabel("Find settings")
        .accessibilityValue(model.isFinding ? "Active" : "")
        .accessibilityAddTraits(.isToggle)
    }

    /// Identity: which Ghostty this is managing. A plain label — the version is
    /// information, not a status — so the old green seal (which falsely read as a
    /// health check) is gone; config health now lives on the Problems sidebar row (D1).
    private func identityChip(_ environment: GhosttyEnvironment) -> some View {
        ToolbarChip(title: "Ghostty \(environment.version)")
            .help("The Ghostty this app is configuring")
    }

    /// A clickable auto-reload status chip (G1): at-a-glance state plus a one-click
    /// toggle, so the setting isn't only reachable from the Settings pane. The pane's
    /// toggle and this chip bind the same stored `autoReloadEnabled`, so they stay in
    /// sync. Exposed to VoiceOver as a switch (not a bare button) per KTD7.
    private func autoReloadChip() -> some View {
        let on = model.autoReloadEnabled
        return ToolbarChip(
            systemImage: "arrow.clockwise",
            tint: on ? .accentColor : .secondary,
            title: on ? "Auto-reload: On" : "Auto-reload: Off",
            isActive: on,
            action: { model.autoReloadEnabled.toggle() }
        )
        .help("Automatically reload Ghostty after each change")
        .accessibilityLabel("Auto-reload")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
