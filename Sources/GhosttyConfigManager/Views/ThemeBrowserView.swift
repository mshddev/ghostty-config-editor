import SwiftUI
import GhosttyConfigKit

/// The theme browser: live palette previews over Ghostty's built-in themes, with
/// honest fidelity labeling and apply-via-safe-write (F2, R12, R14).
struct ThemeBrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        // Compute the filtered list once per render — it folds every theme name
        // (case + diacritic), so reading it three times (subtitle, empty-check, list)
        // would triple that work on each keystroke.
        let filtered = model.filteredThemes
        return VStack(spacing: 0) {
            SurfaceHeader(
                title: "Themes",
                subtitle: model.themes.isEmpty ? nil : "\(filtered.count) theme\(filtered.count == 1 ? "" : "s")",
                searchText: $model.themeQuery,
                searchPrompt: "Search themes"
            )
            disclaimerBar
            Divider()
            if model.themes.isEmpty {
                ProgressView("Loading themes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: model.themeQuery)
            } else {
                List(filtered) { theme in
                    Button {
                        Task { await model.applyTheme(theme.name) }
                    } label: {
                        ThemeRow(theme: theme,
                                 colors: model.themeColors[theme.name],
                                 isCurrent: model.currentTheme == theme.name)
                    }
                    .buttonStyle(.plain)
                    .onAppear { model.ensureColors(for: theme) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(model.currentTheme == theme.name ? "\(theme.name), current theme" : theme.name)
                    .accessibilityHint("Apply this theme")
                }
            }
            // The shared save-state bar (C3) — replaces this surface's hand-rolled
            // feedback; it carries the failure banner and the auto-reload caption (R6)
            // plus Undo, consistent with every other surface.
            SurfaceFeedbackBar(applyState: model.applyState)
        }
        .task { await model.loadThemesIfNeeded() }
    }

    private var disclaimerBar: some View {
        Text(ThemeParser.previewFidelityDisclaimer)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5))
    }
}

private struct ThemeRow: View {
    let theme: ThemeRef
    let colors: ThemeColors?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            preview
                .frame(width: 180, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(
                        isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                        lineWidth: isCurrent ? 2 : 1
                    )
                )
            Text(theme.name)
                .fontWeight(isCurrent ? .bold : .regular)
                .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.vertical, isCurrent ? 10 : 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var preview: some View {
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
        } else {
            Rectangle().fill(.quaternary)
                .overlay(ProgressView().controlSize(.small))
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
