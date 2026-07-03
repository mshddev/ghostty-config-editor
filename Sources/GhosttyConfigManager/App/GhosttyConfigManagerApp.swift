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
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
        .toolbar {
            ToolbarItem(placement: .status) {
                statusChip(environment)
            }
            ToolbarItem(placement: .status) {
                healthChip()
            }
            ToolbarItem(placement: .primaryAction) {
                customizedChip()
            }
        }
    }

    /// The "Customized" entry point, promoted from the sidebar into the window
    /// chrome (mirrors `healthChip`'s button-sets-selection pattern). Tapping it
    /// shows the user's customized options; it tints accent while that view is
    /// active so the current surface is legible from the top bar. The sliders
    /// glyph plus its visible title read as "your adjusted settings" — the bare
    /// pencil it replaced was ambiguous with "edit".
    ///
    /// Built from the same `HStack(spacing: 6)` of icon + text as `statusChip`
    /// and `healthChip` (rather than a `Label`, whose wider icon-title gap and
    /// tighter metrics looked cramped under the Liquid Glass capsule). The
    /// horizontal padding widens the glass capsule so the icon and title clear
    /// its rounded ends — giving the action chip more presence than the adjacent
    /// status chips.
    @ViewBuilder
    private func customizedChip() -> some View {
        let isActive = model.selection == .customized
        Button {
            model.selection = .customized
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .accessibilityHidden(true)
                Text("Customized")
            }
            .font(.caption)
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .help("Show customized options")
        .accessibilityLabel("Customized options")
        .accessibilityAddTraits(isActive ? .isSelected : [])
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

    /// Config-health indicator in the window chrome (moved out of the sidebar).
    /// Tapping it opens the Problems surface (KTD4); icon and tint mirror
    /// `ProblemsView` so the severity language stays consistent (KTD5).
    @ViewBuilder
    private func healthChip() -> some View {
        if let report = model.lintReport {
            Button {
                model.selection = .problems
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: Self.healthIcon(report.health))
                        .foregroundStyle(Self.healthTint(report.health))
                        .accessibilityHidden(true)
                    Text(report.badgeText)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Show config health")
            .accessibilityLabel(report.badgeText)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "stethoscope")
                Text("Checking…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
