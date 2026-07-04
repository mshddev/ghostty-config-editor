import SwiftUI
import GhosttyConfigKit

/// The theme browser: live palette previews over Ghostty's built-in themes, with
/// honest fidelity labeling and apply-via-safe-write (F2, R12, R14).
///
/// Phase E adds: name search + a light/dark appearance badge per row (E1), a pinned
/// "Current theme" section with a non-color "Current" signal that handles light/dark
/// pairs (E2), the fidelity disclaimer folded into the header's info popover plus a
/// non-spinning placeholder for previews that failed to load (E3), and per-row
/// favorites + a light/dark pairing menu (E4).
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
                // E3: the permanent fidelity disclaimer becomes an info popover instead
                // of a row that permanently eats vertical space.
                infoText: ThemeParser.previewFidelityDisclaimer
            )
            Divider()
            content(filtered: filtered)
            // The shared save-state bar (C3) — carries the failure banner, the
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
            // G3: a failed `+list-themes` is a distinct, recoverable state — an error with
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

    @ViewBuilder
    private func loadedList(filtered: [ThemeRef]) -> some View {
        Group {
            let favorites = filtered.filter { model.isFavorite($0.name) }
            let hasPinnedSections = model.currentThemeSelection != nil || !favorites.isEmpty
            List {
                // E2: the current theme is pinned at the very top and stays visible
                // even while filtering, so it's never confusable with row selection.
                if let selection = model.currentThemeSelection {
                    Section("Current theme") {
                        currentRows(selection)
                    }
                }
                // E4: starred themes, quick-access under the pin.
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites) { ThemeRow(theme: $0) }
                    }
                }
                // The full (filtered) list. Only labeled when a pinned section sits
                // above it — a lone unlabeled list reads cleaner on first launch.
                allThemesSection(filtered, labeled: hasPinnedSections)
            }
        }
    }

    @ViewBuilder
    private func allThemesSection(_ filtered: [ThemeRef], labeled: Bool) -> some View {
        let header = model.themeQuery.trimmingCharacters(in: .whitespaces).isEmpty ? "All themes" : "Results"
        if filtered.isEmpty {
            Section(labeled ? header : "") {
                ContentUnavailableView.search(text: model.themeQuery)
            }
        } else if labeled {
            Section(header) { ForEach(filtered) { ThemeRow(theme: $0) } }
        } else {
            Section { ForEach(filtered) { ThemeRow(theme: $0) } }
        }
    }

    /// The pinned Current-theme row(s): one for a single theme, or a labeled Light/Dark
    /// pair. Reuses `ThemeRow` (so it carries the same swatch/star/pairing affordances),
    /// falling back to a plain text row for a value not present in `+list-themes`.
    @ViewBuilder
    private func currentRows(_ selection: ThemeSelection) -> some View {
        switch selection {
        case .single(let name):
            currentRow(name: name, roleCaption: nil)
        case .lightDark(let light, let dark):
            currentRow(name: light, roleCaption: "Light mode")
            currentRow(name: dark, roleCaption: "Dark mode")
        }
    }

    @ViewBuilder
    private func currentRow(name: String, roleCaption: String?) -> some View {
        if let ref = model.themes.first(where: { $0.name == name }) {
            ThemeRow(theme: ref, roleCaption: roleCaption)
        } else {
            // A theme value that isn't a listed theme (a custom name, or one removed
            // on a Ghostty upgrade). Never leave the pin blank — show the raw value.
            HStack(spacing: 8) {
                if let roleCaption {
                    Text(roleCaption).font(.caption).foregroundStyle(.secondary)
                }
                Text(name).lineLimit(1)
                Spacer(minLength: 8)
                Label("Current", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(Color.accentColor)
            }
            .padding(.vertical, RowMetrics.rowVerticalPadding)
        }
    }
}

/// One theme row: a live palette preview, the name, a light/dark appearance badge,
/// a "Current" pill when applied, a favorite star, and a light/dark pairing menu.
/// Tapping the preview/name applies the theme as a single selection. All state is
/// derived from the model so a row re-renders the moment its colors load or fail.
private struct ThemeRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let theme: ThemeRef
    /// When set (pinned Light/Dark pair rows), labels the pairing slot and suppresses
    /// the appearance badge — so "Light mode" (the slot) never collides visually with
    /// the "Light" appearance badge (the theme's own color).
    var roleCaption: String? = nil
    /// Drives the light/dark pairing dialog (U11 — replaces the two-click borderless menu).
    @State private var showingPairing = false

    var body: some View {
        let colors = model.themeColors[theme.name]
        let failed = model.previewFailed(theme.name)
        let isCurrent = model.currentSelectedThemeNames.contains(theme.name)
        HStack(spacing: 8) {
            Button {
                Task { await model.applyTheme(theme.name) }
            } label: {
                rowLabel(colors: colors, failed: failed, isCurrent: isCurrent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(isCurrent: isCurrent, colors: colors))
            .accessibilityHint("Apply this theme")

            favoriteButton
            pairingMenu
        }
        .onAppear { model.ensureColors(for: theme) }
    }

    // MARK: - Row label (tap target)

    private func rowLabel(colors: ThemeColors?, failed: Bool, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            preview(colors: colors, failed: failed)
                .frame(width: 180, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // E2: only a subtle accent preview border marks the current theme —
                // the old full-row accent fill (which mimicked selection) is gone.
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(
                        isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                        lineWidth: isCurrent ? 2 : 1
                    )
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(theme.name)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                    if isCurrent { currentPill }
                }
                // MO-6: the "Current" pill scales in when a theme is applied, matching the
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
        .padding(.vertical, RowMetrics.rowVerticalPadding)
        .contentShape(Rectangle())
    }

    /// The "Current" signal — a non-color pill (icon + text), so it reads without
    /// relying on hue alone (A11Y-7).
    private var currentPill: some View {
        Pill(text: "Current", systemImage: "checkmark.circle.fill", tint: .accentColor, style: .prominent)
    }

    /// E1: light/dark badge, shown once the theme's colors have loaded (never forces
    /// an eager read — an unclassified theme is simply unlabeled).
    private func appearanceBadge(_ appearance: ThemeAppearance) -> some View {
        let isDark = appearance == .dark
        return Pill(text: isDark ? "Dark" : "Light",
                    systemImage: isDark ? "moon.fill" : "sun.max.fill",
                    style: .prominent)
    }

    // MARK: - Preview swatch

    @ViewBuilder
    private func preview(colors: ThemeColors?, failed: Bool) -> some View {
        if let colors {
            ZStack {
                Color(hex: colors.background) ?? Color.black
                VStack(spacing: 2) {
                    HStack(spacing: 0) {
                        ForEach(Array(colors.orderedPalette.prefix(8).enumerated()), id: \.offset) { _, hex in
                            (Color(hex: hex) ?? .gray)
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(Array(colors.orderedPalette.suffix(8).enumerated()), id: \.offset) { _, hex in
                            (Color(hex: hex) ?? .gray)
                        }
                    }
                }
                .padding(6)
                Text("Aa")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color(hex: colors.foreground) ?? .white)
            }
        } else if failed {
            // E3: a distinct, non-spinning placeholder — a failed theme file used to
            // spin forever because `themeColors[name]` stays nil.
            ZStack {
                Rectangle().fill(.quaternary)
                VStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Preview unavailable").font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        } else {
            Rectangle().fill(.quaternary)
                .overlay(ProgressView().controlSize(.small))
        }
    }

    // MARK: - Favorite + pairing controls (E4)

    private var favoriteButton: some View {
        let starred = model.isFavorite(theme.name)
        return Button {
            model.toggleFavorite(theme.name)
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .foregroundStyle(starred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(starred ? "Unstar \(theme.name)" : "Star \(theme.name)")
    }

    /// A left-click button opening a pairing dialog to set this theme as the light
    /// and/or dark member of a `light:…,dark:…` pairing. **Not** a borderless `Menu`:
    /// an `NSMenu` runs a nested modal event loop that *consumes* the click dismissing
    /// it, so applying a different theme while it was open took two clicks (U11/MO-1).
    /// A `confirmationDialog` dismisses cleanly and each action applies on one click.
    private var pairingMenu: some View {
        Button {
            showingPairing = true
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Theme options for \(theme.name)")
        .confirmationDialog("Use \(theme.name) for…",
                            isPresented: $showingPairing,
                            titleVisibility: .visible) {
            Button("Both light and dark") {
                Task { await model.applyTheme(theme.name) }
            }
            Button("Light mode only") {
                Task { await model.applyThemeInPair(theme.name, as: .light) }
            }
            Button("Dark mode only") {
                Task { await model.applyThemeInPair(theme.name, as: .dark) }
            }
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
