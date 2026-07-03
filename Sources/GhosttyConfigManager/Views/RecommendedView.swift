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
            Form {
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
