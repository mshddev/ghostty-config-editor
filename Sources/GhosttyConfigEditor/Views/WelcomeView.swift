import SwiftUI
import AppKit
import GhosttyConfigKit

/// The first-run welcome: a non-modal in-window pane shown on a
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
                jumpIn(title: "Pick a theme",
                       detail: "Browse Ghostty's built-in color themes.",
                       systemImage: "paintpalette") { model.selection = .themes }
                jumpIn(title: "Recommended settings",
                       detail: "The handful of options most people set first.",
                       systemImage: "sparkles") { model.selection = .recommended }
                jumpIn(title: "Describe a change",
                       detail: "Search every setting, or say what you want in plain words.",
                       systemImage: "magnifyingglass") { model.beginFind() }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // The one identity moment: the app's own icon at hero size, over the
                // reserved hero type step — so the welcome outranks routine chrome
                // and reuses the real mark instead of a generic gear.
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                Text(AppInfo.welcomeTitle)
                    .font(.heroTitle)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// A welcome jump-in destination: the shared `SpringboardCard`, wrapped so picking one
    /// also dismisses the welcome (it's marked seen on the first navigation, not later).
    private func jumpIn(title: String, detail: String, systemImage: String, action: @escaping () -> Void) -> some View {
        SpringboardCard(title: title, detail: detail, systemImage: systemImage) {
            action()
            model.dismissWelcome()
        }
    }
}

/// The first-run banner: a clear, one-line explanation shown at the top of the
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
            + Text("~/.config/ghostty/config.ghostty").font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No Ghostty config yet. Your first change will create the file at ~/.config/ghostty/config.ghostty.")
    }
}
