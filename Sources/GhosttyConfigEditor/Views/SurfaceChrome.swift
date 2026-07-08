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

/// U12 (MO-5, IA-4, GAP-2, KTD5): the one hover/focus affordance for strengthenable
/// controls — the ⓘ / reset icon buttons, the Advanced disclosure header, the Welcome
/// jump-in cards, the Find result rows. It lifts the background by the U2 `hoverLift`
/// token on pointer hover **and** on keyboard focus, identically, so no affordance is
/// pointer-only (the KTD5/GAP-2 parity rule; the full keyboard gate is U26). It changes
/// only a tint — no movement or scale — so per HIG it is *not* decorative motion and
/// stays ungated by Reduce Motion.
///
/// `restingFill` gives cards a subtle base the hover lifts *on top of*; `pointingHand`
/// adds the `NSCursor.pointingHand` an unlabeled disclosure needs to read as clickable
/// (IA-4). Icon buttons that already size their own hit target use `.icon` (zero insets).
struct HoverAffordanceButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = DesignTokens.Radius.standard
    var insets: EdgeInsets = EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
    /// An always-present resting fill (the Welcome cards' subtle base); hover/focus lifts
    /// on top of it. Nil for controls that are transparent at rest (icon buttons, rows).
    var restingFill: Color? = nil
    /// Show `NSCursor.pointingHand` on hover — for the otherwise-flat Advanced header.
    var pointingHand: Bool = false

    /// For icon buttons whose label already carries its hit-target frame (the ⓘ / reset
    /// glyphs): zero insets so the lift fills that exact frame, a tight radius.
    static var icon: HoverAffordanceButtonStyle {
        HoverAffordanceButtonStyle(cornerRadius: DesignTokens.Radius.tight, insets: EdgeInsets())
    }

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration,
                  cornerRadius: cornerRadius,
                  insets: insets,
                  restingFill: restingFill,
                  pointingHand: pointingHand)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let insets: EdgeInsets
        let restingFill: Color?
        let pointingHand: Bool
        @State private var hovering = false
        // Tracks whether *this* control currently owns a pushed cursor, so push/pop stay
        // balanced even if `.onHover` delivers a stray or repeated true/false (tracking-
        // area rebuilds on scroll/layout can) — an unmatched pop would corrupt the
        // process-wide cursor stack.
        @State private var didPushCursor = false
        // Best-effort keyboard-focus parity; the guaranteed fallback is the system focus
        // ring the plain button keeps. The full keyboard/VoiceOver gate is U26.
        @Environment(\.isFocused) private var focused: Bool

        var body: some View {
            let lifted = hovering || focused
            configuration.label
                .padding(insets)
                .background {
                    ZStack {
                        if let restingFill {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(restingFill)
                        }
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(DesignTokens.hoverLift)
                            .opacity(lifted ? 1 : 0)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { inside in
                    hovering = inside
                    guard pointingHand else { return }
                    if inside {
                        if !didPushCursor { NSCursor.pointingHand.push(); didPushCursor = true }
                    } else if didPushCursor {
                        NSCursor.pop(); didPushCursor = false
                    }
                }
                // Balance the cursor stack if the control is torn down mid-hover.
                .onDisappear { if didPushCursor { NSCursor.pop(); didPushCursor = false } }
        }
    }
}

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
        // MO-6: a state-triggered pill (a theme's "Current") scales in rather than
        // popping. Inert for the always-present metadata chips — a transition only fires
        // when the pill is conditionally inserted inside an animation transaction.
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

/// A horizontally-scrolling row of filter pills — a leading "All" pill plus one per section
/// — for narrowing a long list to a single group (D). Shared chrome so the Keyboard
/// Shortcuts editor (and later surfaces that want the same horizontal filter) present one
/// consistent control instead of a rigid segmented Picker that can't hold many long titles.
/// `selection` is the chosen section id; `nil` means the "All" pill (show everything).
struct SectionFilterBar: View {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
    }

    let items: [Item]
    @Binding var selection: String?
    /// The label of the "show everything" pill.
    var allTitle: String = "All"

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DesignTokens.Spacing.standard) {
                pill(title: allTitle, isSelected: selection == nil) { selection = nil }
                ForEach(items) { item in
                    pill(title: item.title, isSelected: selection == item.id) { selection = item.id }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.surface)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Filter by section")
    }

    private func pill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                // Bold, high-contrast pills: a readable body-ish size, an unselected label in
                // full primary (not muted secondary), and the selected one filled with the
                // accent in white (KTD4: accent reserved for selection) — a clear, tappable
                // control that holds its own beside the prominent section header.
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, DesignTokens.Spacing.large)
                .padding(.vertical, DesignTokens.Spacing.standard)
                .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(DesignTokens.subtleFill),
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
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
    /// A keyboard-shortcut hint (e.g. "⌘F") shown as a keycap at the trailing edge while the
    /// field is empty, so the shortcut that reaches this search is discoverable at the field
    /// itself (B1). It yields to the clear button the moment the user types — the two are
    /// mutually exclusive on `text.isEmpty`, so they never collide. Nil renders no hint.
    var shortcutHint: String? = nil

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
            } else if let shortcutHint {
                Text(shortcutHint)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.secondary.opacity(0.25))
                    )
                    .accessibilityHidden(true)
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
    /// True once a write has settled (saved or failed) — the point at which feedback
    /// animates in. `.applying` is *not* settled, so it appears instantly (MO-2).
    var isSettled: Bool {
        switch self {
        case .succeeded, .failed: return true
        case .idle, .applying: return false
        }
    }
}

/// The one visual for a settled apply state (DS-10): the icon+headline line over the
/// stacked captions (notice, auto-reload message, git-tracked hint). The per-row
/// feedback (U6) and the surface feedback bar both render this identically — each owns
/// only its own chrome (divider, padding) and action links (Undo / Redo / Reload).
/// Renders nothing while idle or applying (those are placement-specific).
struct ApplyFeedbackContent: View {
    let state: AppModel.ApplyState

    var body: some View {
        switch state {
        case .idle, .applying:
            EmptyView()
        case .succeeded(let headline, let notice, let gitTracked, let reload):
            VStack(alignment: .leading, spacing: 2) {
                Label(headline, systemImage: state.feedbackSymbol)
                    .foregroundStyle(state.feedbackTint).font(.caption)
                if let notice { Text(notice).font(.caption2).foregroundStyle(.secondary) }
                if let reloadMessage = reload.message {
                    Text(reloadMessage).font(.caption2).foregroundStyle(.secondary)
                }
                if gitTracked {
                    Text("This file is git-tracked — commit it in your dotfiles repo.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .failed(let presentation):
            FailedFeedbackLine(presentation: presentation,
                               symbol: state.feedbackSymbol,
                               tint: state.feedbackTint)
        }
    }
}

/// The failure line (KTD4/R3): the normalized plain-language `message` as the headline,
/// plus — only when the writer kept raw diagnostic `detail` — a small info button that
/// reveals it in a popover for troubleshooting. The raw Ghostty text lives in the
/// info/detail context, never in the row headline, so an implementation error string can
/// never masquerade as committed feedback.
private struct FailedFeedbackLine: View {
    let presentation: EditErrorPresentation
    let symbol: String
    let tint: Color
    @State private var showingDetail = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Label(presentation.message, systemImage: symbol)
                .foregroundStyle(tint).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = presentation.detail, !detail.isEmpty {
                Button { showingDetail.toggle() } label: {
                    Image(systemName: "info.circle").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show the raw message from Ghostty")
                .accessibilityLabel("Show error details")
                .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                    ScrollView {
                        Text(detail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(width: 320).frame(maxHeight: 200)
                }
            }
        }
    }
}

/// The top of every surface: a title, an optional secondary count line, an optional
/// per-surface search field, and an optional info button. The search field is **one
/// component bound per-surface** (Options→`query`, Themes→`themeQuery`, Keybindings→
/// its filter) — it filters the *current* surface, never a single global query that
/// means two things at once (the global ⇧⌘F Find is a separate affordance, D2).
/// A "focus this surface's filter field" action, published to the focused scene so the
/// View menu's "Find…" (⌘F) can jump keyboard focus into the per-surface
/// search without the mouse — the keyboard gap System Settings never closed (U26/GAP-2).
/// Only a surface that actually HAS a filter publishes it, so the command disables
/// elsewhere. A menu route (not focus-on-surface-entry) is deliberate: auto-focusing on
/// appear would yank focus out of the sidebar during keyboard row-to-row navigation.
struct SurfaceFilterFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}
extension FocusedValues {
    var focusSurfaceFilter: (() -> Void)? {
        get { self[SurfaceFilterFocusKey.self] }
        set { self[SurfaceFilterFocusKey.self] = newValue }
    }
}

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
    @FocusState private var searchFocused: Bool

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
                SurfaceSearchField(prompt: searchPrompt, text: searchText, focus: $searchFocused,
                                   shortcutHint: "⌘F")
                    // Publish a keyboard route to this filter while the surface is showing.
                    .focusedSceneValue(\.focusSurfaceFilter, { searchFocused = true })
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

/// Shared return affordance for the secondary Customized and Problems drill-downs.
/// Status remains highlighted in the sidebar, while this makes the parent relationship
/// explicit and keyboard-accessible inside the content pane.
struct StatusBackLink: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            // Back to the Status hub via the destination model (KTD6); the sidebar keeps
            // `.status` selected throughout the drill-down.
            Button { model.setStatusDestination(.hub) } label: {
                Label("Back to Status", systemImage: "chevron.left")
            }
            .buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.surface)
        .padding(.vertical, DesignTokens.Spacing.standard)
        .background(.quaternary.opacity(0.5))
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
        case .succeeded:
            bar {
                HStack(alignment: .top, spacing: 8) {
                    ApplyFeedbackContent(state: applyState)
                    Spacer(minLength: 8)
                    if model.canUndo {
                        Button("Undo") { Task { await model.undoLastApply() } }
                            .buttonStyle(.link).font(.caption)
                    } else if model.canRedoApply {
                        Button("Redo") { Task { await model.redoLastApply() } }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        case .failed(let presentation):
            bar {
                HStack(alignment: .top, spacing: 8) {
                    ApplyFeedbackContent(state: applyState)
                    // Stale-on-disk: the fix is a reload, so offer it right on the banner (G3).
                    if presentation.offersReload {
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

/// A "jump-in" springboard card (F3/IA-5): an accent icon, a title, an optional one-line
/// detail, and a trailing chevron, styled as a pickable row with the U12 hover/focus
/// affordance. Extracted as the one shared component behind the Welcome pane's jump-in
/// cards, the empty-Customized springboard, and Recommended's next-steps — so the three
/// "where to go next" surfaces speak one vocabulary and share one look.
struct SpringboardCard: View {
    let title: String
    var detail: String? = nil
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverAffordanceButtonStyle(
            cornerRadius: 10,
            insets: EdgeInsets(),
            restingFill: Color.primary.opacity(0.04)))
        .accessibilityLabel(detail.map { "\(title). \($0)" } ?? title)
    }
}
