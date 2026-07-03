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
    static let defaultWidth: CGFloat = 780
    static let defaultHeight: CGFloat = 600
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
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.maxSize = NSSize(width: WindowMetrics.maxWidth, height: WindowMetrics.maxHeight)
            // Each surface titles itself in its in-content SurfaceHeader (C3), so the
            // title-bar text is redundant — and with the per-surface navigationTitle
            // gone it would otherwise fall back to the truncated app name.
            window.titleVisibility = .hidden
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
            switch model.selection {
            case .problems: ProblemsView()
            case .themes: ThemeBrowserView()
            case .category(let name) where name == OptionCategorizer.keybindingsCategory: KeybindEditorView()
            default: OptionListView()
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
        // "Saved" from the previous one. Centralized here since every surface can
        // surface feedback now, not just the option list (C3).
        .onChange(of: model.selection) { _, _ in model.resetApplyState() }
        .toolbar {
            // Identity and health share one group but are split by a divider, so the
            // version label (identity) stops reading as a health status (LAYOUT-5/7).
            ToolbarItem(placement: .status) {
                HStack(spacing: 10) {
                    identityChip(environment)
                    Divider().frame(height: 14)
                    healthChip()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                customizedChip()
            }
        }
    }

    /// The "Customized" entry point in the window chrome (mirrors the health chip's
    /// button-sets-selection pattern). Tints accent while that surface is active so
    /// the current selection is legible from the top bar.
    private func customizedChip() -> some View {
        let isActive = model.selection == .customized
        return ToolbarChip(
            systemImage: "slider.horizontal.3",
            tint: isActive ? .accentColor : .secondary,
            title: "Customized",
            isActive: isActive,
            action: { model.selection = .customized }
        )
        .help("Show customized options")
        .accessibilityLabel("Customized options")
    }

    /// Identity: which Ghostty this is managing. A plain label — the version is
    /// information, not a status — so the old green seal (which falsely read as a
    /// health check) is gone; the health chip beside it owns the only status glyph.
    private func identityChip(_ environment: GhosttyEnvironment) -> some View {
        ToolbarChip(title: "Ghostty \(environment.version)")
            .help("The Ghostty this app is configuring")
    }

    /// The sole config-health status in the window chrome. Tappable (bordered chrome
    /// + chevron, so it reads as a button) and opens the Problems surface (KTD4); its
    /// icon/tint mirror `ProblemsView` (KTD5). Quiet when clean, tinted with a count
    /// when not. The first-launch "no config file yet" state folds in here rather than
    /// hanging off the identity label.
    @ViewBuilder
    private func healthChip() -> some View {
        if model.configMissing {
            ToolbarChip(systemImage: "doc.badge.plus", tint: .blue, title: "No config yet",
                        showsChevron: true, action: { model.selection = .problems })
                .help("No Ghostty config yet — your first change creates ~/.config/ghostty/config")
                .accessibilityLabel("No config file yet")
        } else if let report = model.lintReport {
            ToolbarChip(systemImage: Self.healthIcon(report.health), tint: Self.healthTint(report.health),
                        title: report.badgeText, showsChevron: true, action: { model.selection = .problems })
                .help("Show config health")
                .accessibilityLabel(report.badgeText)
        } else {
            ToolbarChip(systemImage: "stethoscope", tint: .secondary, title: "Checking…")
        }
    }

    private static func healthIcon(_ health: LintReport.Health) -> String {
        switch health {
        case .clean: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .unknown: return "questionmark.diamond.fill"
        }
    }

    private static func healthTint(_ health: LintReport.Health) -> Color {
        switch health {
        case .clean: return .green
        case .warning, .unknown: return .orange
        case .error: return .red
        }
    }
}
