import SwiftUI
import AppKit
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
                content.foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityAddTraits(isActive ? .isSelected : [])
        } else {
            content.foregroundStyle(.secondary)
        }
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
struct GhosttyConfigManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: WindowMetrics.minWidth, minHeight: WindowMetrics.minHeight)
                .background(WindowConfigurator())   // no fullscreen/zoom, bounded max width
                .task { await model.bootstrap() }
        }
        .windowStyle(.titleBar)
        // Options right-align their value control (the settings idiom), and a wider
        // window only inflates the gap between each label and its control — so the
        // window opens deliberately snug (like System Settings) and can't be zoomed or
        // fullscreened (see `WindowConfigurator`). First launch is centered on screen.
        .defaultSize(width: WindowMetrics.defaultWidth, height: WindowMetrics.defaultHeight)
        .defaultPosition(.center)

        // Standard ⌘, Preferences window for the auto-reload toggle (U3). The model
        // is injected explicitly — SwiftUI does not propagate `.environment` across
        // scenes, so the WindowGroup injection above does not reach this one (KTD7).
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Top-level shell. Until Ghostty is located it shows a status view; once ready
/// it presents the two-column Explorer (sidebar · content). Options are edited
/// inline in the list, so there is no separate detail column.
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
        content.frame(minWidth: WindowMetrics.minWidth, minHeight: WindowMetrics.minHeight)
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
            } else {
                switch model.selection {
                case .recommended: RecommendedView()
                case .problems: ProblemsView()
                case .themes: ThemeBrowserView()
                case .category(let name) where name == OptionCategorizer.keybindingsCategory: KeybindEditorView()
                default: OptionListView()
                }
            }
        }
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
            mainColumn
        }
        // Changing surface clears any lingering apply feedback so the next surface
        // (which may now show its own SurfaceFeedbackBar) doesn't inherit a stale
        // "Saved" from the previous one (C3), and dismisses the global Find overlay so
        // picking a sidebar row leaves Find (D2). Centralized here since every surface
        // can surface feedback now, not just the option list.
        .onChange(of: model.selection) { _, _ in
            model.resetApplyState()
            model.endFind()
        }
        .toolbar {
            // Identity only now — health and Customized moved into the sidebar's
            // Status section (D1), so the top bar carries just "which Ghostty" plus Find.
            ToolbarItem(placement: .status) {
                identityChip(environment)
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
        Button { model.beginFind() } label: {
            Label("Find", systemImage: "magnifyingglass")
        }
        .keyboardShortcut("f", modifiers: .command)
        .help("Find any setting (⌘F)")
        .accessibilityLabel("Find settings")
    }

    /// Identity: which Ghostty this is managing. A plain label — the version is
    /// information, not a status — so the old green seal (which falsely read as a
    /// health check) is gone; config health now lives on the Problems sidebar row (D1).
    private func identityChip(_ environment: GhosttyEnvironment) -> some View {
        ToolbarChip(title: "Ghostty \(environment.version)")
            .help("The Ghostty this app is configuring")
    }
}
