---
date: 2026-06-16
topic: ghostty-config-manager
---

# Ghostty Config Editor — Requirements

## Summary

A native macOS (SwiftUI) configuration tool for the Ghostty terminal, built for the dotfiles power user. It makes Ghostty's config **discoverable** — every macOS-applicable option in the user's installed version, with documentation, default, and the user's current value, searchable by intent — and lets the user tune and save changes back to their plain-text config. It ships in two milestones: a read-first **Explorer** (M1), then in-app **Editing** (M2).

---

## Problem Frame

Editing Ghostty's text config is tedious, and the sharpest pain isn't typing — it's **discovery**. Ghostty has ~185 config options spread across docs (roughly two dozen of which are Linux/GTK-only and filtered from the macOS catalog), and the recurring failure is "a behavior annoys me, but I don't know the option exists to change it." Themes (300+ built-ins) are hidden behind a TUI command; keybind syntax has footguns; config reload gives no visual confirmation. The text file gives you no map of what's possible and no feedback when you get it wrong.

This is built **for the author first** — a personal itch — with community use as real-but-uncertain upside. Two facts shape the bet:

- **No native macOS GUI exists.** Prior art is a maintained web app (no filesystem access, no live preview) and a barely-maintained Python desktop app. The "native, reads your real config, previews live" combination is open territory.
- **An official first-party prefs pane is coming — but slowly, and on a different architecture.** It has no merged code, no accepted issue, and an active process blocker; realistic arrival is ~9–18 months out, basic-first. Critically, it is planned to store settings in **NSUserDefaults and override the text file** — the opposite of a portable, version-controlled config. That leaves the text-native power user deliberately unserved, which is exactly the niche this tool occupies.

---

## Key Decisions

- **Text-native, not NSUserDefaults.** The tool reads and writes the user's plain-text config (`config.ghostty`), keeping it git-friendly and portable. This is the deliberate orthogonal positioning against the official pane, not an implementation convenience.
- **Self-describing catalog.** The option catalog is generated from the user's installed binary (`ghostty +show-config --default --docs`) rather than a hand-maintained list, so it stays current across Ghostty releases and avoids the maintenance treadmill that drags on the existing tools.
- **macOS-scoped catalog.** Even though the catalog is generated from the binary, options that only take effect on Linux/GTK are filtered out before display, so the sidebar, search, All Options, and the "Not Using Yet" surface never present options that are inert on macOS. This extends the macOS-only identity into the catalog itself, not just the build target. The exclusion set is a **curated list** (27 options in Ghostty 1.3.x), not a raw prefix bucket: any `gtk-`/`x11-`/`linux-`/`wayland-`-prefixed option, **plus** 11 doc-confirmed Linux/GTK/Wayland-only options that lack such a prefix — `language`, `async-backend`, `class`, `freetype-load-flags`, `window-subtitle`, `window-show-tab-bar`, `window-titlebar-background`, `window-titlebar-foreground`, `app-notifications`, `quit-after-last-window-closed-delay`, `quick-terminal-keyboard-interactivity`. It must be curated because the CLI output carries no platform tag, so a prefix heuristic is wrong at the edges in both directions: it would over-include `desktop-notifications` (kept — its OSC 9 / OSC 777 notifications work on macOS) and under-include the non-prefixed options above. Membership is read from each option's own `--docs` platform-restriction language ("only applies to GTK", "macOS uses CoreText and does not have an equivalent", …) and revisited as Ghostty adds config keys.
- **Discovery is the headline, by intent.** The product's reason to exist is finding the option that fixes an annoyance — search by behavior/intent and surface options the user isn't yet using — not exposing a parity form of all options.
- **Two milestones, M1 before M2.** M1 (Explorer) is read-only: discover, understand, copy a snippet, reveal in editor. M2 (Studio) adds writing back to the config plus rich visual controls. M1 ships as a useful standalone tool before any write code exists, capping the risk of the hard config-writing problem.
- **Honest preview fidelity.** Color/theme/palette previews are faithful; font-rendering, ligatures, blur, and cursor-style effects are best-effort approximations, because the app does not embed Ghostty's renderer.
- **Personal-use-first success bar.** The tool succeeds if the author reaches for it instead of the text file; community adoption is upside, not the definition of done.

---

## Actors / System Boundaries

The app is single-user, but it brokers between three parties whose contracts matter:

- A1. **The user** — browses, searches, edits, applies.
- A2. **The Ghostty CLI** — the source of truth for the option catalog, themes, fonts, and validation (`+show-config`, `+list-themes`, `+list-fonts`, `+validate-config`, `+list-keybinds`, `+list-actions`).
- A3. **The config file(s)** — the user's plain-text config on disk, possibly split across `config-file` includes, the read source and (M2) the write target.

---

## Key Flows

- F1. Discover an option to fix an annoyance (M1)
  - **Trigger:** Something in Ghostty's behavior annoys the user; they don't know the option name.
  - **Steps:** User searches by intent ("hide title bar") → app maps it to the relevant option(s) → user reads docs, default, and their current value → copies the config snippet or reveals the line in their editor.
  - **Covered by:** R1, R2, R4, R5, R6

- F2. Browse and apply a theme (M2)
  - **Trigger:** User wants a different look but can't see the 300+ themes.
  - **Steps:** User opens the theme browser → previews palette/colors faithfully → applies → app writes `theme = …` to the config → reports apply success and whether a reload/new surface is needed.
  - **Covered by:** R12, R13, R8, R17

- F3. Edit and save safely (M2)
  - **Trigger:** User changes an option value in-app.
  - **Steps:** App validates the result → creates a recoverable backup → writes back preserving comments and untouched lines → confirms success or surfaces the validation error.
  - **Covered by:** R8, R9, R10, R11, R15

---

## Requirements

**Discovery & Option Catalog (M1)**

- R1. The app presents every config option available in the user's installed Ghostty **that can take effect on macOS**, sourced from the binary's own output, so the catalog stays current across releases without manual updates. Linux/GTK-only options are excluded (see Key Decisions: *macOS-scoped catalog*).
- R2. Each option shows its documentation, default value, and — where determinable — its accepted type or enumerated values.
- R3. Options are browsable by category and searchable by option name.
- R4. Search supports intent/behavior queries (e.g., "transparent background", "hide title bar") that map natural phrasing to the relevant option(s), not just literal name matching.

**Config Awareness (M1)**

- R5. The app reads the user's active config — resolving Ghostty's search-path precedence, including `config.ghostty` — and shows, per option, whether it is unset (default), set to the default, or set to a non-default value.
- R6. The app surfaces options the user is not currently setting as discoverable, directly serving the core discovery goal — excluding Linux/GTK-only options, so discovery never recommends a change that has no effect on macOS.
- R7. When the config is split across `config-file` includes, the app resolves included files when determining current values.

**Editing & Persistence (M2)**

- R8. The app writes changes back to the user's text config, preserving existing comments, ordering, and untouched lines.
- R9. Editing correctly handles additive/repeatable keys (`keybind`, `palette`, `font-feature`, `env`) without collapsing them to a single value.
- R10. Before writing, the app creates a recoverable backup (or equivalent safeguard) so a bad write can always be reverted.
- R11. The app never silently destroys config content; existing content it cannot confidently parse is preserved rather than rewritten.

**Appearance & Preview (M2)**

- R12. The app provides a theme browser over Ghostty's built-in themes with a faithful visual preview of palette and colors, removing the apply-and-reload loop for evaluating a theme.
- R13. Visual options (colors, palette, font family, padding, opacity) get type-appropriate controls — color pickers, font pickers, sliders — rather than raw text entry.
- R14. The app communicates preview fidelity honestly: color/theme/palette previews are faithful; font-rendering, ligature, blur, and cursor-style effects are labeled best-effort approximations.

**Validation & Safety (M1 read / M2 write)**

- R15. The app validates config via `ghostty +validate-config` and reports errors clearly.
- R16. The app warns on known footguns — notably the bare `keybind =` that clears all keybinds — and flags keybind triggers likely to conflict or silently fail.
- R17. Applying a change gives explicit success/failure feedback (addressing Ghostty's silent-reload gap) and tells the user when a change only takes effect in new terminals/surfaces.

**Platform & Resilience (cross-cutting)**

- R18. The app is a native macOS SwiftUI application.
- R19. The app degrades gracefully when the `ghostty` binary is absent or an unexpected version, with clear messaging rather than a broken catalog, since it depends on the CLI.

---

## Acceptance Examples

- AE1. **Covers R5, R6.** Given the user's config sets `font-size = 16` and never mentions `cursor-style`, when they open the catalog, then `font-size` shows as "set (non-default: 16)" and `cursor-style` shows as "not set — default: block" and appears in the "you're not using this" surface.
- AE2. **Covers R9.** Given the config contains four `keybind = …` lines, when the user edits one keybind in-app and saves, then the other three keybind lines remain intact and only the targeted line changes.
- AE3. **Covers R8, R11.** Given the config has a `# my splits` comment and a line the app doesn't recognize, when the user changes an unrelated option and saves, then the comment and the unrecognized line are preserved verbatim.
- AE4. **Covers R16.** Given the user is about to write a bare `keybind =`, when they attempt to apply it, then the app warns that this clears all keybinds (including defaults) before proceeding.
- AE5. **Covers R17.** Given the user changes an option that only applies to new surfaces, when they apply it, then the app confirms the save and states the change affects new terminals, not the current session.

---

## Success Criteria

- The author reaches for this tool instead of hand-editing the text file or grepping docs.
- M1 ships and is genuinely useful (discovery works end to end) before any write-path code exists.
- Zero config-corruption incidents: a bad write is always recoverable.
- Catalog correctness: for a given installed Ghostty version, no macOS-applicable options are missing — a direct payoff of the self-describing approach.
- Handoff: `ce-plan` can produce an implementation plan without re-deciding scope, positioning, or success criteria.

---

## Scope Boundaries

**Deferred for later (post-v1):**

- Recipe library / outcome-oriented config snippets ("tmux-style splits" → ready block).
- Config annotation ("explain my existing config line by line").
- Config profiles and switching between multiple configs.
- Config diffing and sharing.
- A full visual keybinding builder with a conflict graph (beyond the footgun warnings in R16).

**Outside this product's identity:**

- NSUserDefaults-backed settings that override the text file — that is the official pane's model; this tool is deliberately text-native.
- A comprehensive "form for all 185 options" as the product's reason to exist — discovery plus the text-native/visual wedge is the identity.
- Cross-platform (Linux/Windows) builds.
- Surfacing Linux/GTK-only config options in the catalog — filtered out per R1/R6 (see Key Decisions: *macOS-scoped catalog*). The plain-text writer still preserves any such lines already in the user's file (R8/R11), so a portable, cross-machine config is never corrupted; the options are just not browsable or discoverable in-app.
- Competing with the eventual first-party pane on basic option coverage.
- Embedding a real Ghostty terminal for pixel-perfect preview.

---

## Dependencies / Assumptions

- Depends on the `ghostty` CLI being present and its `+`-command output being parseable: `+show-config --default --docs`, `+list-themes`, `+list-fonts`, `+validate-config`, `+list-keybinds`, `+list-actions`.
- **Assumption (load-bearing, unverified at depth):** no machine-readable config schema exists today, so option/type metadata must be parsed from CLI text or a thin fallback catalog. The CLI output format is treated as a stable-enough contract; format drift is a known risk.
- Assumes Ghostty's documented config format and search-path precedence, including `config.ghostty` as the first search path.
- Assumes the official prefs pane is ~9–18 months out and arrives basic-first; the tool's durability rests on staying text-native and discovery-focused regardless of when it lands.
- Personal-use-first: success does not depend on community adoption.

---

## Outstanding Questions

**Deferred to Planning:**

- Value-type metadata strategy: rely solely on parsing `+show-config --default --docs`, or maintain a thin fallback catalog for types/enums the CLI text doesn't expose cleanly (affects R2)?
- Intent-search mapping: curated synonyms/keyword map vs. heuristic matching (affects R4)?
- Backup/undo mechanism for the write path (affects R10).
- When the config spans multiple `config-file` includes, which file does a given write target, and how is that surfaced to the user (affects R8)?
- How to define the macOS-scoped exclusion set, and where to apply it (at catalog build vs. per discovery surface) (affects R1, R6). The existing "Linux / GTK" prefix bucket is a starting point but not a reliable platform oracle: it over-includes `desktop-notifications` (works on macOS) and under-includes GTK-only options filed elsewhere (`app-notifications`, `window-subtitle`). Likely a small curated allowlist of genuinely-inert options, derived once and revisited as Ghostty adds config keys.

---

## Sources / Research

External grounding gathered during this brainstorm (planner breadcrumbs):

- Ghostty config, keybind, and theme docs: https://ghostty.org/docs/config , https://ghostty.org/docs/config/keybind , https://ghostty.org/docs/features/theme
- Ghostty CLI reference (the `+` commands driving the catalog/validation): https://man.archlinux.org/man/ghostty.1
- Official prefs-pane status (durability context): discussions https://github.com/ghostty-org/ghostty/discussions/2354 and https://github.com/ghostty-org/ghostty/discussions/10807 ; closed PR https://github.com/ghostty-org/ghostty/pull/10529
- Prior art: web tool https://github.com/zerebos/ghostty-config ; Python desktop tool https://github.com/d3cker/GhosttyConfigGUI
- UX reference for native terminal prefs: https://iterm2.com/documentation-preferences.html
