import SwiftUI
import GhosttyConfigKit

/// The theme browser: live palette previews over Ghostty's built-in themes, with
/// honest fidelity labeling and apply-via-safe-write (F2, R12, R14).
struct ThemeBrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            disclaimerBar
            if model.themes.isEmpty {
                ProgressView("Loading themes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.themes) { theme in
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
            if case .failed(let message) = model.applyState {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption).padding(8)
            }
        }
        .navigationTitle("Themes")
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
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(theme.name)
                    if isCurrent {
                        Text("current").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.green.opacity(0.2), in: Capsule())
                    }
                }
                Text(theme.source).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
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
