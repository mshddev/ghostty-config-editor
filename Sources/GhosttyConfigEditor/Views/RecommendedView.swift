import SwiftUI
import GhosttyConfigKit

/// The curated "Recommended" surface (F1, ONBOARD-3, IA-10): a short, grouped list of
/// the settings most people set first, so a newcomer meets ~a dozen meaningful choices
/// instead of the 300-option wall. It reuses the ordinary option rows (Phase B) with
/// their friendly labels and inline controls; `theme` — which has a rich dedicated
/// browser — is rendered as a deep-link into Themes rather than a raw field.
///
/// Not the launch default: the app still opens on Themes to preserve its identity
/// (Open Question #2). This surface is reachable from the pinned sidebar row.
struct RecommendedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader(
                title: "Recommended",
                subtitle: "Start here",
                infoText: "A short list of the settings most people set first. Change anything here, or explore every option in the categories on the left."
            )
            Divider()
            content
        }
        .navigationSplitViewColumnWidth(min: 360, ideal: 460)
    }

    @ViewBuilder
    private var content: some View {
        if model.browser == nil {
            ProgressView("Loading catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            @Bindable var model = model
            Form {
                // Auto-reload is an *app* behavior, not a Ghostty option key, so it's a
                // hardcoded toggle here (like `themeRow` and "Next steps") rather than a
                // recommended catalog row. Surfaced first so a newcomer meets "the app
                // reloads Ghostty when you save" before changing anything. It also lives on
                // Status; both bind the same `autoReloadEnabled`, so the two never drift.
                Section("Live reload") {
                    Toggle("Automatically reload Ghostty after changes", isOn: $model.autoReloadEnabled)
                    Text("After each saved change, the app asks the running Ghostty to reload its config so live terminals update right away. Uses Ghostty's reload signal — needs Ghostty 1.2 or newer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.recommendedSections()) { section in
                    Section(section.title) {
                        ForEach(section.options) { option in
                            if option.option.name == "theme" {
                                themeRow
                            } else {
                                OptionRow(option: option)
                            }
                        }
                    }
                }
                // A closing next-step block (IA-5): the two concrete places to go after the
                // recommended settings — themes and free-form Find — via the shared
                // springboard component. No no-op "browse" filler. Clear the Form's own row
                // background/insets so the card supplies all the chrome (no card-in-card
                // against the grouped Section's rounded row).
                Section("Next steps") {
                    SpringboardCard(title: "Pick a theme",
                                    detail: "Browse Ghostty's built-in color themes.",
                                    systemImage: "paintpalette") { model.selection = .themes }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    SpringboardCard(title: "Describe a change",
                                    detail: "Search every setting, or say what you want in plain words.",
                                    systemImage: "magnifyingglass") { model.beginFind() }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
        }
    }

    /// `theme` deep-links to the Themes browser (its real home) instead of showing a
    /// raw text field — the same "one home per setting" rule the option lists follow by
    /// filtering `theme` out. Shows the currently-applied theme as context.
    private var themeRow: some View {
        DeepLinkRow(
            title: LabelCatalog.bundled.displayTitle(for: "theme"),
            subtitle: "Pick from Ghostty's built-in themes.",
            value: model.currentTheme ?? "Not set",
            linkLabel: "Edit in Themes",
            systemImage: "paintpalette",
            action: { model.focus(optionNamed: "theme") }
        )
    }
}
