import SwiftUI
import AppKit
import GhosttyConfigKit

/// Shared chrome so every surface — Options, Themes, Keybindings, Problems — titles,
/// searches, and reports its save-state in the same place with the same density
/// (LAYOUT-10, LAYOUT-11). Three pieces: `SurfaceHeader` (top), `SurfaceFeedbackBar`
/// (bottom), and `RowMetrics` (the shared row rhythm).

/// Shared spacing/type rhythm for list rows, so a row on one surface reads at the
/// same density as a row on another. Grouped `Form` and `List` supply their own base
/// insets; these add a small, uniform breathing room and a common title/subtitle role.
enum RowMetrics {
    /// Extra vertical breathing room applied to each row's content.
    static let rowVerticalPadding: CGFloat = 4
    /// The row's primary label.
    static let titleFont: Font = .body
    /// The row's one-line secondary summary.
    static let subtitleFont: Font = .caption
}

// MARK: - Design tokens (DS-3, DS-12, GAP-7)

/// The single source of spacing, corner-radius, and tint constants every surface
/// consumes, so no view hand-picks a literal (DS-3). The primitives are framework-
/// neutral (`CGFloat`/`Color`) so the AppKit `KeyRecorderView` can share the same
/// radius. Tint fills sit over **dynamic** system bases (`.secondary`/`.primary`/
/// `.accentColor`), so they adapt to light and dark rather than baking a dark-assumed
/// alpha (GAP-1).
enum DesignTokens {
    enum Spacing {
        static let tight: CGFloat = 4
        static let snug: CGFloat = 6
        static let standard: CGFloat = 8
        static let cozy: CGFloat = 12
        static let large: CGFloat = 16
        /// The horizontal inset every surface's content shares.
        static let surface: CGFloat = 20
    }

    enum Radius {
        static let tight: CGFloat = 4
        static let standard: CGFloat = 6
        static let card: CGFloat = 10
        /// The search-field pill radius (its established value, kept in one place).
        static let field: CGFloat = 8
    }

    /// A soft neutral fill for search fields, subtle chips, and at-rest chrome.
    static let subtleFill = Color.secondary.opacity(0.10)
    /// The accent-tinted fill for a selected/current status pill.
    static let accentFill = Color.accentColor.opacity(0.15)
    /// The background lift a control gains on hover / keyboard focus (U12 consumes it).
    static let hoverLift = Color.primary.opacity(0.06)

    /// The **non-accent** tint for the customized-state cue — the small row state dot
    /// (U5). KTD4 keeps accent for selection/current/primary only, so a changed-from-
    /// default value gets its own hue; this matches the in-repo "Replaces a default"
    /// orange. A system dynamic color, so it stays legible in light and dark (GAP-1).
    static let customizedTint = Color.orange
}

/// Named durations + curves for the app's small motion vocabulary (KTD5). Transitions
/// that consume these are reduce-motion gated via `gated(_:reduceMotion:)`; a hover
/// tint is not motion and stays ungated.
enum MotionSystem {
    /// A quick cross-fade — feedback appearing, an overlay showing (~0.15s).
    static let quickFade: Animation = .easeOut(duration: 0.15)
    /// A weightier settle — a selection landing, a value committing (~0.25s).
    static let settle: Animation = .easeOut(duration: 0.25)

    /// The animation to use, honoring Reduce Motion: nil (instant) when it is on. The one
    /// helper both the SwiftUI environment flag and the AppKit `NSWorkspace` flag route
    /// through (GAP-7).
    static func gated(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// The AppKit-side Reduce Motion flag for `KeyRecorderView`, mirroring SwiftUI's
    /// `\.accessibilityReduceMotion` environment value.
    static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// The two-step semantic type scale (DS-8): `surfaceTitle` is the routine per-surface
/// header; `heroTitle` is the one reserved larger step for the single identity moment
/// (Welcome, applied by U22), so it visibly outranks ordinary chrome.
extension Font {
    static let surfaceTitle = Font.title2.weight(.semibold)
    static let heroTitle = Font.largeTitle.weight(.semibold)
}

// MARK: - Shared components

/// The one small tinted capsule for status/metadata across every surface — "Customized",
/// a theme's "Current", a Find result's category, a keybind's origin (DS-3). Replaces six
/// hand-rolled capsules. `tint` colors both the soft fill and the label; `.prominent`
/// deepens the fill for a primary status like "Current".
struct Pill: View {
    enum Style { case subtle, prominent }
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary
    var style: Style = .subtle

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(style == .prominent ? 0.15 : 0.12), in: Capsule())
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
    }
}

/// A Form-row button that reads unambiguously destructive — **explicit** red, because
/// macOS grouped Forms drop `role: .destructive`-only styling (DS-7). The reset-all rows
/// consume it (U24).
struct DestructiveRowButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Text(title).foregroundStyle(.red)
        }
    }
}

/// The one search-field recipe shared by every surface header and the global Find
/// overlay (DS-12): a magnifying-glass icon, a plain text field, and a clear button on
/// the neutral `subtleFill`. An optional `FocusState` binding lets Find drive
/// focus-on-appear (and U26 make the per-surface field keyboard-reachable).
struct SurfaceSearchField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.snug) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
                .accessibilityHidden(true)
            field
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.standard)
        .padding(.vertical, DesignTokens.Spacing.snug)
        .background(DesignTokens.subtleFill, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.field))
    }

    @ViewBuilder private var field: some View {
        if let focus {
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focus)
        } else {
            TextField(prompt, text: $text).textFieldStyle(.plain)
        }
    }
}

/// The shared save-state vocabulary (icon + tint) so the surface feedback bar and the
/// inline per-row feedback (U6) map a state the same way instead of drifting (DS-10).
/// Behavior — collapse timing, Undo/Reload placement — stays in the views.
extension AppModel.ApplyState {
    var feedbackSymbol: String {
        switch self {
        case .idle, .applying: return ""
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
    var feedbackTint: Color {
        switch self {
        case .idle, .applying: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}

/// The top of every surface: a title, an optional secondary count line, an optional
/// per-surface search field, and an optional info button. The search field is **one
/// component bound per-surface** (Options→`query`, Themes→`themeQuery`, Keybindings→
/// its filter) — it filters the *current* surface, never a single global query that
/// means two things at once (the global ⌘F Find is a separate affordance, D2).
struct SurfaceHeader: View {
    let title: String
    /// A secondary line under the title, e.g. "142 shortcuts" or "7 results". Hidden when nil.
    var subtitle: String? = nil
    /// When provided, renders the shared search field bound to this surface's query.
    var searchText: Binding<String>? = nil
    var searchPrompt: String = "Search"
    /// Optional info popover text (e.g. a fidelity disclaimer). Hidden when nil.
    var infoText: String? = nil

    @State private var showingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.surfaceTitle)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let infoText {
                    infoButton(infoText)
                }
            }
            if let searchText {
                SurfaceSearchField(prompt: searchPrompt, text: searchText)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.surface)
        .padding(.top, DesignTokens.Spacing.large)
        .padding(.bottom, 10)
    }

    private func infoButton(_ text: String) -> some View {
        Button { showingInfo.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("About this surface")
        .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(14)
        }
    }
}

/// A row that *navigates* to the surface which owns a setting rather than editing it
/// inline — used where a value has a rich dedicated home: `theme` → the Themes browser,
/// `keybind` → the Keyboard Shortcuts surface (F1 Recommended, F3 Customized). This
/// keeps the "one home per setting" rule so a value with a real editor is never also a
/// raw field somewhere else (the two-ways-to-set-the-same-key footgun).
struct DeepLinkRow: View {
    let title: String
    /// A one-line description under the title. Hidden when empty.
    var subtitle: String = ""
    /// A current-value summary shown before the link (e.g. the active theme). Hidden when empty.
    var value: String = ""
    let linkLabel: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(RowMetrics.titleFont)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(RowMetrics.subtitleFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if !value.isEmpty {
                Text(value)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button(action: action) {
                // Trailing chevron via the label text so it reads as "go there →".
                Label("\(linkLabel) →", systemImage: systemImage)
            }
            .buttonStyle(.link)
        }
        .padding(.vertical, RowMetrics.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.isEmpty ? title : "\(title), \(value)")
        .accessibilityHint(linkLabel)
    }
}

/// The bottom of a surface: one consistent place for save-state (Saving… / Saved ·
/// Undo / error) plus the auto-reload caption, shared by Themes and Keybindings so
/// they stop hand-rolling their own bars. Options keeps its richer *per-row* feedback
/// (Phase B) — its edits are inline, so the confirmation belongs next to the control
/// you changed, not at the bottom of the list. Renders nothing while idle.
struct SurfaceFeedbackBar: View {
    @Environment(AppModel.self) private var model
    let applyState: AppModel.ApplyState

    var body: some View {
        switch applyState {
        case .idle:
            EmptyView()
        case .applying:
            bar {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .succeeded(let notice, let gitTracked, let reload):
            bar {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Label("Saved", systemImage: applyState.feedbackSymbol)
                            .foregroundStyle(applyState.feedbackTint).font(.caption)
                        Spacer(minLength: 8)
                        if model.canUndo {
                            Button("Undo") { Task { await model.undoLastApply() } }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                    if let notice { Text(notice).font(.caption2).foregroundStyle(.secondary) }
                    if let reloadMessage = reload.message {
                        Text(reloadMessage).font(.caption2).foregroundStyle(.secondary)
                    }
                    if gitTracked {
                        Text("This file is git-tracked — commit it in your dotfiles repo.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let message, let offersReload):
            bar {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(message, systemImage: applyState.feedbackSymbol)
                        .foregroundStyle(applyState.feedbackTint).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    // Stale-on-disk: the fix is a reload, so offer it right on the banner (G3).
                    if offersReload {
                        Spacer(minLength: 8)
                        Button("Reload") { Task { await model.reloadFromDisk() } }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Divider()
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }
}
