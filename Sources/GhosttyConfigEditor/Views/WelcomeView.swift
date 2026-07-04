import SwiftUI
import GhosttyConfigKit

/// The first-run welcome (F2, ONBOARD-1/7/9/10): a non-modal in-window pane shown on a
/// fresh install (or whenever there's no config yet), re-openable any time from Help.
/// It leads with a one-line value prop, then — crucially — the **safety story** before
/// the user changes anything (writes are validated, applied live, and undoable), then
/// three jump-in cards. Dismissing marks it seen (not the first edit), so a returning
/// user with an existing config meets it exactly once.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            // A scrim so the card reads as the focus; tapping it dismisses (non-modal —
            // nothing here traps the user).
            Rectangle()
                .fill(.black.opacity(0.28))
                .ignoresSafeArea()
                .onTapGesture { model.dismissWelcome() }
                .accessibilityHidden(true)

            card
                .frame(maxWidth: 440)
                .padding(24)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            safetyStrip
            VStack(spacing: 8) {
                jumpInCard(
                    title: "Pick a theme",
                    detail: "Browse Ghostty's built-in color themes.",
                    systemImage: "paintpalette",
                    action: { model.selection = .themes }
                )
                jumpInCard(
                    title: "Recommended settings",
                    detail: "The handful of options most people set first.",
                    systemImage: "sparkles",
                    action: { model.selection = .recommended }
                )
                jumpInCard(
                    title: "Describe a change",
                    detail: "Search every setting, or say what you want in plain words.",
                    systemImage: "magnifyingglass",
                    action: { model.beginFind() }
                )
            }
            HStack {
                Spacer()
                Button("Explore on my own") { model.dismissWelcome() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 1))
        .shadow(radius: 24, y: 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.2.fill")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(AppInfo.welcomeTitle)
                    .font(.title2.weight(.semibold))
            }
            Text("Configure Ghostty visually — every setting in one place, no config-file syntax to learn.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The reassurance strip — the safety story shown *before* the first edit so a
    /// newcomer knows changes are checked, live, and reversible.
    private var safetyStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Changes are checked by Ghostty before saving, applied to your open terminals automatically, and can be undone. You can turn auto-reload off in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func jumpInCard(title: String, detail: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            model.dismissWelcome()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        // U12: the card's subtle resting fill, lifted by the hover/focus token on top —
        // so pointer and keyboard both show the same "this is pickable" strengthening.
        .buttonStyle(HoverAffordanceButtonStyle(
            cornerRadius: 10,
            insets: EdgeInsets(),
            restingFill: Color.primary.opacity(0.04)))
        .accessibilityLabel("\(title). \(detail)")
    }
}

/// The first-run banner (F2): a clear, one-line explanation shown at the top of the
/// content while no config exists yet — replacing the tiny "No config" whisper with a
/// plain statement of what the first change will do.
struct FirstRunBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("No Ghostty config yet — your first change will create ")
                .foregroundStyle(.secondary)
            + Text("~/.config/ghostty/config").font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No Ghostty config yet. Your first change will create the file at ~/.config/ghostty/config.")
    }
}
