import SwiftUI
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
                    .font(.title2.weight(.semibold))
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
                searchField(searchText)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func searchField(_ text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
                .accessibilityHidden(true)
            TextField(searchPrompt, text: text)
                .textFieldStyle(.plain)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
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
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
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
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).font(.caption)
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
