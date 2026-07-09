import SwiftUI
import GhosttyConfigKit

/// The flagship theme-row actions: exactly one Apply, one Favorite, and one Theme
/// Options control per theme, each with a distinct, task-specific accessibility label shared by
/// the list row AND the grid card — so neither can drift into a duplicate or "mystery" control,
/// and Apply / Favorite / Options stay three separate accessibility elements. Pure, so the
/// one-of-each + distinct-label guarantee is unit-testable without rendering SwiftUI.
enum ThemeActionPolicy {
    enum Kind: String, CaseIterable, Hashable, Sendable { case apply, favorite, options }

    struct Descriptor: Equatable {
        let kind: Kind
        /// The label the control exposes to VoiceOver.
        let accessibilityLabel: String
        /// Apply carries its verb as a *hint* (its label is the theme identity, so VoiceOver
        /// announces the theme, then the action); nil for Favorite/Options whose label already
        /// names the action.
        let accessibilityHint: String?
        let systemImage: String
    }

    /// The three actions for a theme, given its favorite state and the identity string the
    /// Apply control announces (name + appearance + current). Exactly one descriptor per kind.
    struct Actions: Equatable {
        let apply: Descriptor
        let favorite: Descriptor
        let options: Descriptor
        /// All three in canonical order — one per kind.
        var all: [Descriptor] { [apply, favorite, options] }
    }

    static func actions(themeName: String, isFavorite: Bool, applyIdentityLabel: String) -> Actions {
        Actions(
            apply: Descriptor(kind: .apply, accessibilityLabel: applyIdentityLabel,
                              accessibilityHint: "Apply this theme", systemImage: "paintbrush"),
            favorite: Descriptor(kind: .favorite,
                                 accessibilityLabel: isFavorite ? "Unstar \(themeName)" : "Star \(themeName)",
                                 accessibilityHint: nil, systemImage: isFavorite ? "star.fill" : "star"),
            options: Descriptor(kind: .options, accessibilityLabel: "Theme options for \(themeName)",
                                accessibilityHint: nil, systemImage: "ellipsis.circle")
        )
    }
}

/// The pure browsing-bucket dedup behind the Themes list/grid: a Current
/// theme is pinned and never re-appears in Favorites or the main browse list, and the Favorites
/// band (only surfaced while browsing everything) never doubles the Current theme. Extracted
/// from the view so the dedup survives the flagship-row cleanup and is unit-testable across
/// favorite/filter/current transitions.
enum ThemeSectionPolicy {
    struct Buckets: Equatable {
        var favorites: [ThemeRef]
        var browse: [ThemeRef]
    }

    static func buckets(filtered: [ThemeRef],
                        currentNames: Set<String>,
                        isFavorite: (String) -> Bool,
                        filter: ThemeFilter) -> Buckets {
        // The Favorites *section* is only surfaced while browsing everything: a Dark/Light/
        // Favorites filter already scopes the main list, so a duplicate favorites band would be
        // redundant (and under the favorites filter would swallow the whole list). Under a
        // filter, favorites simply live in the main list.
        let showFavorites = filter == .all
        let favorites = showFavorites
            ? filtered.filter { isFavorite($0.name) && !currentNames.contains($0.name) }
            : []
        // Keep the current theme in the main list (it renders its own in-list active state
        // — accent border + "Current" pill — and also still appears in the pinned "Current
        // theme" section, 2026-07-09). Only the Favorites band is deduped out of browse, so
        // a starred theme isn't shown twice.
        let pinned = Set(favorites.map(\.name))
        let browse = filtered.filter { !pinned.contains($0.name) }
        return Buckets(favorites: favorites, browse: browse)
    }
}

/// The theme browser: live palette previews over Ghostty's built-in themes, with
/// honest fidelity labeling and apply-via-safe-write.
///
/// It also provides: name search + a light/dark appearance badge per row, a pinned
/// "Current theme" section with a non-color "Current" signal that handles light/dark
/// pairs, the fidelity disclaimer folded into the header's info popover plus a
/// non-spinning placeholder for previews that failed to load, and per-row
/// favorites + a light/dark pairing menu.
struct ThemeBrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        // Compute the filtered list once per render — it folds every theme name
        // (case + diacritic), so reading it repeatedly would multiply that work
        // on each keystroke.
        let filtered = model.filteredThemes
        return VStack(spacing: 0) {
            SurfaceHeader(
                title: "Themes",
                subtitle: model.themes.isEmpty ? nil : "\(filtered.count) theme\(filtered.count == 1 ? "" : "s")",
                searchText: $model.themeQuery,
                searchPrompt: "Search themes",
                // The permanent fidelity disclaimer becomes an info popover instead
                // of a row that permanently eats vertical space.
                infoText: ThemeParser.previewFidelityDisclaimer
            )
            // Appearance/favorites filter + list/grid toggle, only once themes load
            // (no filter to offer over a spinner or an error).
            if case .loaded = model.themesLoad {
                themeToolbar(model: model)
            }
            Divider()
            content(filtered: filtered)
            // The shared save-state bar — carries the failure banner, the
            // auto-reload caption, and Undo, consistent with every other surface.
            SurfaceFeedbackBar(applyState: model.applyState)
        }
        .task { await model.loadThemesIfNeeded() }
    }

    @ViewBuilder
    private func content(filtered: [ThemeRef]) -> some View {
        switch model.themesLoad {
        case .idle, .loading:
            ProgressView("Loading themes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            // A failed `+list-themes` is a distinct, recoverable state — an error with
            // a "Try again", not the eternal spinner it used to show (themeColors[name] nil).
            ContentUnavailableView {
                Label("Couldn't load themes", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Ghostty's theme list couldn't be read.\n\(reason)")
            } actions: {
                Button("Try again") { Task { await model.reloadThemes() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            loadedList(filtered: filtered)
        }
    }

    /// The appearance/favorites filter and the list/grid toggle. The
    /// first Dark/Light selection kicks off the one-time batch classification (its
    /// determinate count shows inline); a later selection is instant (memoized).
    private func themeToolbar(model: AppModel) -> some View {
        @Bindable var model = model
        return HStack(spacing: DesignTokens.Spacing.cozy) {
            Picker("Filter themes", selection: $model.themeFilter) {
                ForEach(ThemeFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: model.themeFilter) { _, new in
                if new.needsClassification {
                    Task { await model.classifyThemesIfNeeded() }
                }
            }
            if let remaining = model.classifyProgress {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    ProgressView().controlSize(.small)
                    Text("Classifying \(remaining)…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DesignTokens.Spacing.standard)
            Picker("View as", selection: $model.themeViewMode) {
                // Grid leads the control since it's the default view (2026-07-08).
                Image(systemName: "square.grid.2x2").tag(ThemeViewMode.grid)
                    .accessibilityLabel("Grid")
                Image(systemName: "list.bullet").tag(ThemeViewMode.list)
                    .accessibilityLabel("List")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("View as")
        }
        .padding(.horizontal, DesignTokens.Spacing.surface)
        .padding(.bottom, 10)
    }

    // MARK: - Deduped section model

    /// The three browsing buckets after dedupe, computed once so a favorite never also
    /// appears in the main list and Current never doubles inside Favorites.
    /// The current theme intentionally *stays* in the main list (highlighted in place),
    /// while also appearing in its pinned "Current theme" section (2026-07-09).
    private struct Sections {
        var current: ThemeSelection?
        var favorites: [ThemeRef]
        var browse: [ThemeRef]
        var browseHeader: String
        var hasPinned: Bool { current != nil || !favorites.isEmpty }
    }

    private func sections(filtered: [ThemeRef]) -> Sections {
        // The pinned/favorites/browse dedup is the pure `ThemeSectionPolicy` (unit-tested)
        // so it survives the flagship-row cleanup unchanged.
        let buckets = ThemeSectionPolicy.buckets(filtered: filtered,
                                                 currentNames: model.currentSelectedThemeNames,
                                                 isFavorite: { model.isFavorite($0) },
                                                 filter: model.themeFilter)
        let header = model.themeQuery.trimmingCharacters(in: .whitespaces).isEmpty ? "All themes" : "Results"
        return Sections(current: model.currentThemeSelection,
                        favorites: buckets.favorites,
                        browse: buckets.browse,
                        browseHeader: header)
    }

    @ViewBuilder
    private func loadedList(filtered: [ThemeRef]) -> some View {
        let s = sections(filtered: filtered)
        switch model.themeViewMode {
        case .list: listBody(s)
        case .grid: gridBody(s)
        }
    }

    // MARK: - List mode (default)

    @ViewBuilder
    private func listBody(_ s: Sections) -> some View {
        // The list is the compact, name-first scan view: fixed-height rows with a small
        // resting swatch and no hover behaviour at all. Grid (the default) is where a theme's
        // full-size preview lives, so the list deliberately never enlarges or previews on
        // hover — nothing moves or pops as you scan (2026-07-08).
        List {
            // The current theme is pinned at the very top (a quick jump-reference) and
            // stays visible even while filtering. It ALSO stays in the list below,
            // highlighted in place, so applying a theme never makes it vanish (2026-07-09).
            if let selection = s.current {
                Section("Current theme") { currentRows(selection, layout: .row) }
            }
            // Starred themes, quick-access under the pin.
            if !s.favorites.isEmpty {
                Section("Favorites") { ForEach(s.favorites) { ThemeRow(theme: $0) } }
            }
            allThemesSection(s)
        }
    }

    @ViewBuilder
    private func allThemesSection(_ s: Sections) -> some View {
        if s.browse.isEmpty {
            // Only labeled when a pinned section sits above — a lone unlabeled list reads
            // cleaner on first launch.
            Section(s.hasPinned ? s.browseHeader : "") { emptyBrowse }
        } else if s.hasPinned {
            Section(s.browseHeader) { ForEach(s.browse) { ThemeRow(theme: $0) } }
        } else {
            Section { ForEach(s.browse) { ThemeRow(theme: $0) } }
        }
    }

    /// The empty state, distinguishing "still classifying", "no search results", "no
    /// favorites yet", and a genuinely empty filter, so it never reads as a broken list.
    @ViewBuilder
    private var emptyBrowse: some View {
        if model.themeFilter.needsClassification && !model.didClassifyAll {
            // Dark/Light before the batch finishes: only a few lazily-loaded rows are
            // classified yet, so the bucket can be momentarily empty. Don't claim "no dark
            // themes" while the toolbar is still counting down — that reads as broken.
            ContentUnavailableView {
                Label("Classifying themes…", systemImage: "circle.dotted")
            } description: {
                Text("Sorting themes into light and dark.")
            }
        } else if !model.themeQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: model.themeQuery)
        } else if model.themeFilter == .favorites {
            ContentUnavailableView("No favorites yet", systemImage: "star",
                                   description: Text("Tap the ☆ on any theme to keep it here."))
        } else {
            ContentUnavailableView("No themes", systemImage: "paintpalette",
                                   description: Text("No \(model.themeFilter.title.lowercased()) themes to show."))
        }
    }

    // MARK: - Grid mode

    /// The minimum card width; the grid fits as many columns of at least this width as the
    /// pane allows and degrades to one column below the threshold. Themes now use the
    /// wider bounded canvas (`ContentWidthPolicy.wideMaxWidth`, 1000pt) rather than the 640pt
    /// form measure, so a maximized window fits three columns of 280pt where it used to fit
    /// two — Themes "uses available width" while forms stay readable.
    private static let minCardWidth: CGFloat = 280

    /// Grid browsing: the deduped sections as `LazyVGrid`s under plain headers in
    /// one `ScrollView`. The column count is measured from the pane width (a `GeometryReader`)
    /// and rendered with `.flexible()` columns, so the grid always fills the pane — a plain
    /// `.adaptive` grid collapsed to a single left-aligned column in this split-view detail.
    private func gridBody(_ s: Sections) -> some View {
        GeometryReader { geo in
            let spacing = DesignTokens.Spacing.large
            let available = geo.size.width - DesignTokens.Spacing.surface * 2
            let count = max(1, Int((available + spacing) / (Self.minCardWidth + spacing)))
            let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
                    if let selection = s.current {
                        gridSection("Current theme") {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                                currentRows(selection, layout: .card)
                            }
                        }
                    }
                    if !s.favorites.isEmpty {
                        gridSection("Favorites") {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                                ForEach(s.favorites) { ThemeRow(theme: $0, layout: .card) }
                            }
                        }
                    }
                    if s.browse.isEmpty {
                        if s.hasPinned { sectionHeaderText(s.browseHeader) }
                        emptyBrowse.frame(maxWidth: .infinity).padding(.vertical, DesignTokens.Spacing.large)
                    } else {
                        gridSection(s.hasPinned ? s.browseHeader : nil) {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                                ForEach(s.browse) { ThemeRow(theme: $0, layout: .card) }
                            }
                        }
                    }
                }
                .padding(DesignTokens.Spacing.surface)
            }
        }
    }

    @ViewBuilder
    private func gridSection<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.standard) {
            if let title { sectionHeaderText(title) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeaderText(_ title: String) -> some View {
        Text(title)
            .font(.subheadline).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: - Current-theme rows/cards

    /// The pinned Current-theme entries: one for a single theme, or a labeled Light/Dark
    /// pair. Rendered as rows or cards via the shared `themeItem`, which reuses `ThemeRow`
    /// (so the same preview/star/pairing affordances) and falls back to a placeholder-
    /// preview row for a value not present in `+list-themes`.
    @ViewBuilder
    private func currentRows(_ selection: ThemeSelection, layout: ThemeRow.Layout) -> some View {
        let entries = currentEntries(selection)
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            themeItem(name: entry.name, roleCaption: entry.role, layout: layout)
        }
    }

    private func currentEntries(_ selection: ThemeSelection) -> [(name: String, role: String?)] {
        switch selection {
        case .single(let name): return [(name, nil)]
        case .lightDark(let light, let dark): return [(light, "Light mode"), (dark, "Dark mode")]
        }
    }

    @ViewBuilder
    private func themeItem(name: String, roleCaption: String?, layout: ThemeRow.Layout) -> some View {
        if let ref = model.themes.first(where: { $0.name == name }) {
            ThemeRow(theme: ref, roleCaption: roleCaption, layout: layout)
        } else {
            // A current value that isn't a listed theme (a custom name, or one
            // removed on a Ghostty upgrade). Keep the row *consistent* — a synthetic ref
            // whose preview is forced to the "unavailable" placeholder, with the star and
            // pairing menu (keyed by name) still working — rather than a bare text line.
            ThemeRow(theme: ThemeRef(name: name, source: "user", path: ""),
                     roleCaption: roleCaption, layout: layout, forcePlaceholder: true)
        }
    }
}

/// One theme row: a live palette preview, the name, a light/dark appearance badge,
/// a "Current" pill when applied, a favorite star, and a light/dark pairing menu.
/// Tapping the preview/name applies the theme as a single selection. All state is
/// derived from the model so a row re-renders the moment its colors load or fail.
private struct ThemeRow: View {
    /// Row (list) vs card (grid) presentation of the same theme.
    enum Layout { case row, card }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let theme: ThemeRef
    /// When set (pinned Light/Dark pair rows), labels the pairing slot and suppresses
    /// the appearance badge — so "Light mode" (the slot) never collides visually with
    /// the "Light" appearance badge (the theme's own color).
    var roleCaption: String? = nil
    /// Row or card layout.
    var layout: Layout = .row
    /// Force the "unavailable" placeholder preview and skip color loading — for the
    /// synthetic current-theme fallback (a name not in `+list-themes`), so an unknown
    /// current theme still reads as a proper row (star + menu work) rather than bare text.
    var forcePlaceholder: Bool = false
    /// Drives the light/dark pairing dialog (replaces the two-click borderless menu).
    @State private var showingPairing = false

    var body: some View {
        let colors = forcePlaceholder ? nil : model.themeColors[theme.name]
        let failed = forcePlaceholder || model.previewFailed(theme.name)
        let isCurrent = model.currentSelectedThemeNames.contains(theme.name)
        // The one Apply / Favorite / Theme Options descriptor set, shared by the row
        // and card so both read identical labels from a single pure source.
        let actions = ThemeActionPolicy.actions(
            themeName: theme.name,
            isFavorite: model.isFavorite(theme.name),
            applyIdentityLabel: accessibilityLabel(isCurrent: isCurrent, colors: colors))
        Group {
            switch layout {
            case .row: rowBody(colors: colors, failed: failed, isCurrent: isCurrent, actions: actions)
            case .card: cardBody(colors: colors, failed: failed, isCurrent: isCurrent, actions: actions)
            }
        }
        .onAppear { if !forcePlaceholder { model.ensureColors(for: theme) } }
    }

    // MARK: - Row body (list)

    private func rowBody(colors: ThemeColors?, failed: Bool, isCurrent: Bool,
                         actions: ThemeActionPolicy.Actions) -> some View {
        HStack(spacing: 8) {
            // Apply: the preview/name IS the button; it announces the theme identity and
            // carries "Apply this theme" as its hint — a distinct, single accessibility
            // element, never merged with the star/options controls beside it.
            Button {
                Task { await model.applyTheme(theme.name) }
            } label: {
                rowLabel(colors: colors, failed: failed, isCurrent: isCurrent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(actions.apply.accessibilityLabel)
            .accessibilityHint(actions.apply.accessibilityHint ?? "")

            favoriteButton(actions.favorite)
            pairingMenu(actions.options)
        }
        .padding(.vertical, RowMetrics.rowVerticalPadding)
        .padding(.horizontal, DesignTokens.Spacing.snug)
        // The list is deliberately flat: no hover tint, no enlarge — nothing changes as the
        // pointer moves across it (2026-07-08). Grid is the view for full-size previews.
        .contentShape(Rectangle())
    }

    private func rowLabel(colors: ThemeColors?, failed: Bool, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            // A compact, fixed-size preview swatch — enough to read the palette at a glance
            // while scanning by name. The full-size preview lives in grid view.
            ThemePreviewSwatch(colors: colors, failed: failed)
                .frame(width: 180, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // Only a subtle accent preview border marks the current theme —
                // the old full-row accent fill (which mimicked selection) is gone.
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(
                        isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                        lineWidth: isCurrent ? 2 : 1
                    )
                )
                // The current border settles in when a theme is applied.
                .animation(MotionSystem.gated(MotionSystem.settle, reduceMotion: reduceMotion),
                           value: isCurrent)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(theme.name)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                    if isCurrent { currentPill }
                }
                // The "Current" pill scales in when a theme is applied, matching the
                // option-row state dot. Keyed to `isCurrent` so nothing else animates.
                .animation(MotionSystem.gated(MotionSystem.settle, reduceMotion: reduceMotion),
                           value: isCurrent)
                if let roleCaption {
                    Text(roleCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let appearance = colors?.appearance {
                    appearanceBadge(appearance)
                }
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Card body (grid)

    private func cardBody(colors: ThemeColors?, failed: Bool, isCurrent: Bool,
                          actions: ThemeActionPolicy.Actions) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.standard) {
            Button {
                Task { await model.applyTheme(theme.name) }
            } label: {
                ThemePreviewSwatch(colors: colors, failed: failed, enlarged: true)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.card).strokeBorder(
                            isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                            lineWidth: isCurrent ? 2 : 1
                        )
                    )
                    // The current border settles in on apply.
                    .animation(MotionSystem.gated(MotionSystem.settle, reduceMotion: reduceMotion),
                               value: isCurrent)
                    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(actions.apply.accessibilityLabel)
            .accessibilityHint(actions.apply.accessibilityHint ?? "")

            HStack(spacing: 6) {
                // Name + pill + badge repeat what the apply Button's `accessibilityLabel`
                // already announces (unlike the list row, where they live *inside* the
                // Button's label). Hidden from VoiceOver so a card is one announcement, not
                // three; the star/pairing keep their own labels (three separate elements).
                Text(theme.name)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                if isCurrent { currentPill.accessibilityHidden(true) }
                Spacer(minLength: 4)
                favoriteButton(actions.favorite)
                pairingMenu(actions.options)
            }
            .animation(MotionSystem.gated(MotionSystem.settle, reduceMotion: reduceMotion),
                       value: isCurrent)
            if let roleCaption {
                Text(roleCaption).font(.caption2).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else if let appearance = colors?.appearance {
                appearanceBadge(appearance).accessibilityHidden(true)
            }
        }
        .padding(DesignTokens.Spacing.standard)
        // Flat at rest and on hover — the card already shows the full-size preview, so there's
        // nothing to reveal; its controls stay permanently visible (below) rather than fading in.
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    /// The "Current" signal — a non-color pill (icon + text), so it reads without
    /// relying on hue alone.
    private var currentPill: some View {
        Pill(text: "Current", systemImage: "checkmark.circle.fill", tint: .accentColor, style: .prominent)
    }

    /// Light/dark badge, shown once the theme's colors have loaded (never forces
    /// an eager read — an unclassified theme is simply unlabeled).
    private func appearanceBadge(_ appearance: ThemeAppearance) -> some View {
        let isDark = appearance == .dark
        return Pill(text: isDark ? "Dark" : "Light",
                    systemImage: isDark ? "moon.fill" : "sun.max.fill",
                    style: .prominent)
    }

    // MARK: - Favorite + pairing controls

    /// The one Favorite control, driven by the shared `ThemeActionPolicy` descriptor so
    /// the star glyph + label are identical in list and grid. State reads without color: the
    /// filled/empty star and the "Star"/"Unstar" label both carry it (scenario 6).
    private func favoriteButton(_ descriptor: ThemeActionPolicy.Descriptor) -> some View {
        let starred = model.isFavorite(theme.name)
        return Button {
            // Animate the section membership move (All ↔ Favorites) so the row
            // visibly relocates rather than teleporting.
            withAnimation(MotionSystem.gated(MotionSystem.settle, reduceMotion: reduceMotion)) {
                model.toggleFavorite(theme.name)
            }
        } label: {
            Image(systemName: descriptor.systemImage)
                .foregroundStyle(starred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(descriptor.accessibilityLabel)
    }

    /// The one Theme Options control, driven by the shared `ThemeActionPolicy`
    /// descriptor. Its purpose is now *only* the light/dark pairing — the former "Use for
    /// both" item was a hidden second Apply (identical to tapping the preview), the
    /// duplicate/mystery action, so it's removed: Apply lives in exactly one place
    /// (the preview button) and Theme Options is unambiguously "assign to a light/dark slot".
    ///
    /// A left-click button opening a `confirmationDialog` — **not** a borderless `Menu`: an
    /// `NSMenu` runs a nested modal event loop that *consumes* the click dismissing it, so
    /// applying a different theme while it was open took two clicks. A
    /// `confirmationDialog` dismisses cleanly and each action applies on one click.
    private func pairingMenu(_ descriptor: ThemeActionPolicy.Descriptor) -> some View {
        Button {
            showingPairing = true
        } label: {
            Image(systemName: descriptor.systemImage).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(descriptor.accessibilityLabel)
        .confirmationDialog("Use \(theme.name) for…",
                            isPresented: $showingPairing,
                            titleVisibility: .visible) {
            // Action-first copy that reads back as a sentence with the title —
            // "Use <name> for… Use for Light mode / Use for Dark mode". "Use for both" is
            // gone (it duplicated Apply); apply-as-single is the preview button.
            Button("Use for Light mode") {
                Task { await model.applyThemeInPair(theme.name, as: .light) }
            }
            Button("Use for Dark mode") {
                Task { await model.applyThemeInPair(theme.name, as: .dark) }
            }
            // Explicit cancel: without it SwiftUI adds an ambiguous "OK" that reads like a
            // confirm but does nothing. "Cancel" states plainly that it abandons (found in
            // live testing).
            Button("Cancel", role: .cancel) { }
        }
    }

    private func accessibilityLabel(isCurrent: Bool, colors: ThemeColors?) -> String {
        var parts = [theme.name]
        if let roleCaption { parts.append(roleCaption) }
        if isCurrent { parts.append("current theme") }
        if let appearance = colors?.appearance { parts.append(appearance == .dark ? "dark" : "light") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Shared preview swatch

/// The theme preview swatch content (a miniature terminal, not a chip grid): a live
/// `TerminalMockup`, or a non-spinning "unavailable" placeholder, or a loading tile.
/// Shared by the list row and the grid card so both render an identical swatch from one
/// source — compact in the list, full-size (`enlarged`) in the grid.
private struct ThemePreviewSwatch: View {
    let colors: ThemeColors?
    let failed: Bool
    /// The enlarged mockup (bigger type, a third line, taller footer) — grid cards; the
    /// resting list swatch stays compact.
    var enlarged: Bool = false

    var body: some View {
        if let model = colors.flatMap(ThemePreviewModel.resolve) {
            TerminalMockup(model: model, large: enlarged)
        } else if failed || colors != nil {
            // A failed load, *or* colors that loaded but lack background/foreground: the
            // nil-fallback contract renders the placeholder, never an empty cell.
            unavailablePreview
        } else {
            Rectangle().fill(.quaternary)
                .overlay(ProgressView().controlSize(.small))
        }
    }

    /// A distinct, non-spinning placeholder — a failed (or bg/fg-less) theme file
    /// used to spin forever because `themeColors[name]` stays nil.
    private var unavailablePreview: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            VStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle")
                Text("Preview unavailable").font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// A miniature terminal that previews a theme's *actual* colors: a
/// prompt line in a palette accent, an output line carrying a selected token, and — when
/// enlarged — a foreground sample, over the theme background with a 16-color ANSI footer
/// strip. Flat composition (no material, no shadow) so 400+ of them scroll smoothly.
/// The row's Button owns the accessibility label, so the mockup is decorative.
private struct TerminalMockup: View {
    let model: ThemePreviewModel
    /// The enlarged form — the grid card and the hover preview: bigger type,
    /// a third foreground line, a taller footer.
    var large: Bool = false

    private var fontSize: CGFloat { large ? 12 : 8 }
    private var lineSpacing: CGFloat { large ? 5 : 2 }
    private var pad: CGFloat { large ? 12 : 6 }

    var body: some View {
        let bg = Color(hex: model.background) ?? .black
        let fg = Color(hex: model.foreground) ?? .white
        ZStack {
            bg
            VStack(alignment: .leading, spacing: lineSpacing) {
                promptLine(fg: fg)
                outputLine(fg: fg)
                if large {
                    Text("The quick brown fox").foregroundStyle(fg).opacity(0.85)
                }
                Spacer(minLength: 0)
                footerStrip
            }
            .font(.system(size: fontSize, design: .monospaced))
            .lineLimit(1)
            .padding(pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Decorative: the row/card Button carries the real "name, appearance, current" label.
        .accessibilityHidden(true)
    }

    /// `~ $ ` in the prompt accent, a command in foreground, then the cursor block.
    private func promptLine(fg: Color) -> some View {
        let prompt = Color(hex: model.prompt) ?? fg
        let cursor = Color(hex: model.cursor) ?? fg
        return HStack(spacing: 0) {
            Text("~ $ ").foregroundStyle(prompt)
            Text("ghostty").foregroundStyle(fg)
            cursor
                .frame(width: fontSize * 0.55, height: fontSize)
                .padding(.leading, 1)
        }
    }

    /// An output arrow in the second ANSI color, a *selected* token (selection bg/fg),
    /// then foreground — so cursor, selection, prompt, output, and foreground all show.
    private func outputLine(fg: Color) -> some View {
        let output = Color(hex: model.output) ?? fg
        let selBg = Color(hex: model.selectionBackground) ?? fg
        let selFg = Color(hex: model.selectionForeground) ?? (Color(hex: model.background) ?? .black)
        return HStack(spacing: 0) {
            Text("▸ ").foregroundStyle(output)
            Text("Themes")
                .foregroundStyle(selFg)
                .padding(.horizontal, 1)
                .background(selBg)
            Text(" ready").foregroundStyle(fg)
        }
    }

    /// The 16-dot ANSI palette strip, a thin secondary footer. Hidden for a theme with
    /// no palette (nothing to show) rather than rendering an empty bar.
    @ViewBuilder private var footerStrip: some View {
        if !model.palette.isEmpty {
            HStack(spacing: 0.5) {
                ForEach(Array(model.palette.prefix(16).enumerated()), id: \.offset) { _, hex in
                    (Color(hex: hex) ?? .gray)
                }
            }
            .frame(height: large ? 5 : 3)
            .clipShape(RoundedRectangle(cornerRadius: 1))
        }
    }
}

extension Color {
    /// Build a Color from a hex string. Accepts an optional `#`/`0x` prefix and
    /// 3- (rgb), 6- (rrggbb), or 8-digit (rrggbbaa) forms.
    init?(hex: String?) {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespaces).lowercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        else if hex.hasPrefix("0x") { hex.removeFirst(2) }

        let expanded = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
        guard expanded.count == 6 || expanded.count == 8,
              let value = UInt64(expanded, radix: 16) else { return nil }

        let hasAlpha = expanded.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self = Color(red: r, green: g, blue: b, opacity: a)
    }
}
