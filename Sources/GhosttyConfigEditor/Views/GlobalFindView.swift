import SwiftUI
import GhosttyConfigKit

/// The global **Find** overlay (⌘F — U20, search tier 2). Unlike a surface's own local
/// filter (which narrows *that* surface), Find searches **every** option — by name,
/// description, and described behavior (the intent map) — from anywhere in the app, and
/// presents ranked results with provenance: a category pill on every row, and for a
/// behavior match the curated phrase that surfaced it. Picking a result jumps straight
/// to that option via the shared `focus(optionNamed:)` navigation primitive (D1).
///
/// The field is a plain `TextField` driven by `@FocusState` — not `.searchable`, which
/// exposes no programmatic-focus API — so opening Find (⌘F or the toolbar button) can
/// deterministically place the caret here.
struct GlobalFindView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        // Resolve results once per render and hand the count to the header, so the
        // ranked search isn't run twice per keystroke.
        let hits = model.globalFindHits()
        let trimmed = model.findQuery.trimmingCharacters(in: .whitespaces)
        return VStack(spacing: 0) {
            header(query: $model.findQuery,
                   resultCount: trimmed.isEmpty ? nil : hits.count)
            Divider()
            results(hits, searching: !trimmed.isEmpty)
        }
        // Place the caret in the field as Find appears, so the user can type immediately.
        .task { fieldFocused = true }
    }

    // MARK: - Header

    private func header(query: Binding<String>, resultCount: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Find")
                    .font(.surfaceTitle)
                if let resultCount {
                    Text("\(resultCount) result\(resultCount == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Done") { model.endFind() }
                    .keyboardShortcut(.cancelAction)   // Esc closes Find
            }
            SurfaceSearchField(prompt: "Find any setting — name, description, or behavior",
                               text: query, focus: $fieldFocused)
        }
        .padding(.horizontal, DesignTokens.Spacing.surface)
        .padding(.top, DesignTokens.Spacing.large)
        .padding(.bottom, 10)
    }

    // MARK: - Results

    @ViewBuilder
    private func results(_ hits: [(hit: SearchHit, option: MergedOption)], searching: Bool) -> some View {
        if !searching {
            // Nothing typed yet — explain what Find spans rather than showing a blank pane.
            ContentUnavailableView {
                Label("Find any setting", systemImage: "magnifyingglass")
            } description: {
                Text("Search across every category by name, description, or what you want to do — e.g. “transparent”, “stop cursor blinking”, or a raw key like “macos-titlebar-style”.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hits.isEmpty {
            ContentUnavailableView.search(text: model.findQuery)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // A broad query can rank hundreds of options (name + intent + full-text doc
            // match), so results use a virtualized List — matching the option list's own
            // search branch (C3 review fix), not an eager Form.
            List(hits.map(FindResult.init)) { result in
                FindResultRow(hit: result.hit, option: result.option)
            }
        }
    }
}

/// One ranked result, wrapped so the List has a stable, unambiguous identity (the
/// option name) without reaching into a tuple key path.
private struct FindResult: Identifiable {
    let hit: SearchHit
    let option: MergedOption
    var id: String { option.id }

    init(_ pair: (hit: SearchHit, option: MergedOption)) {
        self.hit = pair.hit
        self.option = pair.option
    }
}

/// One global-Find result: the option's friendly title, a category pill, a provenance
/// note (why it matched, when the name didn't), and its one-line summary. The whole row
/// is a button that jumps to the option (D1's `focus(optionNamed:)`) and dismisses Find.
private struct FindResultRow: View {
    @Environment(AppModel.self) private var model
    let hit: SearchHit
    let option: MergedOption

    var body: some View {
        Button {
            model.focus(optionNamed: option.option.name)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.option.displayTitle)
                            .font(RowMetrics.titleFont)
                        categoryPill
                    }
                    provenance
                    if !summary.isEmpty {
                        Text(summary)
                            .font(RowMetrics.subtitleFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.vertical, RowMetrics.rowVerticalPadding)
        }
        // U12: the whole result row lifts on hover/focus so it reads as the jump target.
        .buttonStyle(HoverAffordanceButtonStyle(cornerRadius: DesignTokens.Radius.standard,
                                                insets: EdgeInsets()))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens this setting")
    }

    private var summary: String { option.option.shortSummary }

    /// The category this option lives in — the pill that orients a result surfaced from
    /// another surface ("this is in Appearance").
    private var categoryPill: some View {
        Pill(text: option.option.category, style: .prominent)
    }

    /// Why this option surfaced, shown only when the *name* didn't obviously match: a
    /// behavior (intent) match names the phrase that matched ("matches: transparent
    /// background"); a description-only match is labeled so the result doesn't look
    /// arbitrary. A plain name match needs no explanation.
    @ViewBuilder
    private var provenance: some View {
        if let phrase = hit.intentPhrase {
            Label("matches: \(phrase)", systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
        } else if hit.matchKind == .documentation {
            Label("found in description", systemImage: "text.magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityLabel: String {
        var parts = [option.option.displayTitle, "in \(option.option.category)"]
        if let phrase = hit.intentPhrase { parts.append("matches \(phrase)") }
        if !summary.isEmpty { parts.append(summary) }
        return parts.joined(separator: ", ")
    }
}
