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
                    ThemeRow(theme: theme,
                             colors: model.themeColors[theme.name],
                             isCurrent: model.currentTheme == theme.name)
                        .onAppear { model.ensureColors(for: theme) }
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await model.applyTheme(theme.name) } }
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
            Button("Apply") { /* handled by row tap; explicit affordance */ }
                .buttonStyle(.borderless)
                .opacity(0) // keep layout; tap-to-apply is the gesture
        }
        .padding(.vertical, 3)
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
    /// Build a Color from a `#rrggbb` (or `#rgb`) hex string.
    init?(hex: String?) {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 3, let value = UInt64(
            hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex, radix: 16
        ) else { return nil }
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
