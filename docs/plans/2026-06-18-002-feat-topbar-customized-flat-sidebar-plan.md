---
title: "feat: Move Customized entry point to the top bar and flatten the sidebar"
type: feat
date: 2026-06-18
status: ready
depth: lightweight
---

# feat: Move Customized entry point to the top bar and flatten the sidebar

## Summary

Two small, related sidebar/chrome changes:

1. **Move the "Customized" entry point into the window top bar**, mirroring the
   existing config-health chip pattern that already lives there. The sidebar row
   under the "Discover" section goes away.
2. **Remove the sidebar section headers** ("Discover", "Appearance",
   "Categories") and render the remaining entries — Themes plus the option
   categories — as a single flat list.

Both are presentation-only changes confined to the app target. The selection
model (`SidebarSelection.customized`), its content routing, and the option-list
title already handle `.customized` end-to-end — only the *entry point location*
and the sidebar *section chrome* change.

---

## Problem Frame

The leading sidebar currently groups entries under three section headers:

- `Discover` → **Customized** (`pencil`, `.customized`)
- `Appearance` → **Themes** (`paintpalette`, `.themes`)
- `Categories` → one row per option category (`.category(...)`)

The user wants the "Customized" view promoted to the window top bar (alongside
the Ghostty-version chip and the config-health chip that already live there),
and the remaining sidebar collapsed into a flat, header-less list. The prior
"top-bar config-health" work established the precedent: a navigation entry point
that opens a surface by setting `model.selection` reads well as a top-bar chip
and de-clutters the sidebar.

---

## Requirements

- **R1.** A "Customized" control appears in the window top bar and, when
  activated, sets the current selection to `.customized` (showing the user's
  customized options in the middle column).
- **R2.** The "Customized" row no longer appears in the sidebar.
- **R3.** The sidebar no longer renders the "Discover", "Appearance", or
  "Categories" section headers; Themes and the category rows render as one flat
  list.
- **R4.** Existing selection routing is preserved: selecting `.customized`,
  `.themes`, or any `.category(...)` continues to show the same content as
  before (the only change is *how* `.customized` is entered and *how* the list
  is grouped).

---

## Key Technical Decisions

- **KTD1 — Mirror the `healthChip()` pattern for the top-bar entry.** The
  Customized control is a `Button` inside a `ToolbarItem`, set via the existing
  `.toolbar { … }` in `RootView.browser(_:)`, whose action sets
  `model.selection = .customized`. This reuses the exact shape already proven by
  `healthChip()` (which sets `model.selection = .problems`) — same styling
  vocabulary (`.buttonStyle(.plain)`, `.font(.caption)`, a `.help(...)` string,
  an accessibility label), so the two top-bar entry points stay visually and
  behaviorally consistent.
- **KTD2 — Keep `pencil` as the Customized icon.** It is the icon the sidebar
  row used today; carrying it to the top bar preserves recognition and matches
  the `pencil` empty-state icon already in `OptionListView`.
- **KTD3 — Reflect the active selection in the top-bar control.** When
  `model.selection == .customized`, tint the control with the accent color so
  the user can tell the Customized view is active. This is a light touch
  (foreground style switch), not a new control style. `healthChip()` does not do
  this because it is a status badge; the Customized control is a view toggle, so
  active-state feedback is worth the few lines.
- **KTD4 — Flat list, no replacement grouping.** Per the request, remove the
  three `Section(...)` wrappers and render entries directly in the `List`. Order
  is preserved: Themes first, then the categories from `model.categories`. No
  divider or implicit grouping is introduced — "flat list" is taken literally.
- **KTD5 — No change to `SidebarSelection`, routing, or the kit.** `.customized`
  remains a valid selection; `RootView.browser(_:)` already falls through to
  `OptionListView` for it, `AppModel.visibleOptions` already maps it to
  `browser.customizedOptions`, and `OptionListView.title` already returns
  "Customized". This work touches only two SwiftUI view files.

---

## Implementation Units

### U1. Move the "Customized" entry point to the top bar

**Goal:** Add a top-bar Customized control and remove the Customized row (and the
now-empty "Discover" section) from the sidebar.

**Requirements:** R1, R2, R4

**Dependencies:** none

**Files:**
- `Sources/GhosttyConfigEditor/App/GhosttyConfigEditorApp.swift` — add a
  `customizedChip()` (or inline `ToolbarItem`) to the existing `.toolbar` in
  `browser(_:)`, mirroring `healthChip()`.
- `Sources/GhosttyConfigEditor/Views/SidebarView.swift` — remove the
  `Section("Discover")` block containing the Customized `Label`.

**Approach:**
- In `RootView.browser(_:)`, add a `ToolbarItem` whose content is a `Button`
  that sets `model.selection = .customized`. Label it
  `Label("Customized", systemImage: "pencil")`, style it like `healthChip()`
  (`.buttonStyle(.plain)`, `.font(.caption)`, `.help("Show customized options")`,
  an `.accessibilityLabel`). Per KTD3, switch its foreground style to
  `.accentColor` when `model.selection == .customized`, otherwise the default.
- Place it alongside the existing status items. Use a placement consistent with
  the other top-bar entries; `.status` keeps it grouped with the version and
  health chips, which is the established home for top-bar entry points here. (If
  the implementer finds a leading `.navigation` placement reads better next to
  the sidebar toggle, that is an acceptable equivalent — the decision that
  matters is "top bar, healthChip-style button".)
- In `SidebarView`, delete the `Section("Discover") { … }` wrapper and its
  `Customized` label entirely.

**Patterns to follow:** `healthChip()` in
`Sources/GhosttyConfigEditor/App/GhosttyConfigEditorApp.swift` — same
`ToolbarItem` → `Button` → set-`model.selection` shape, styling, and help/a11y
strings.

**Test scenarios:** Test expectation: none — SwiftUI view-only change in the
app target, which has no test harness (all logic lives in `GhosttyConfigKit`,
and `.customized` routing is already covered there via `CatalogBrowser`).
Verified by build + launch (see Verification).

**Verification:** App builds and launches; a "Customized" control is visible in
the top bar; clicking it shows the customized-options list (or the "Nothing
customized yet" empty state) in the middle column with the "Customized" title;
the control reflects the accent tint while `.customized` is active; the sidebar
no longer shows a "Customized" row or a "Discover" header.

---

### U2. Flatten the sidebar into a section-less list

**Goal:** Remove the remaining sidebar section headers ("Appearance",
"Categories") so Themes and the category rows render as one flat list.

**Requirements:** R3, R4

**Dependencies:** U1 (the "Discover" section/Customized row is already gone)

**Files:**
- `Sources/GhosttyConfigEditor/Views/SidebarView.swift` — remove the
  `Section("Appearance")` and `Section("Categories")` wrappers; render the
  Themes `Label` and the `ForEach(model.categories…)` directly in the `List`.
  Update the view's doc comment, which currently describes "discovery shortcuts
  plus option categories".

**Approach:**
- Inside `List(selection: $model.selection)`, drop the two `Section(...)`
  containers and place their child rows directly: the Themes `Label`
  (`.tag(SidebarSelection.themes)`) first, then the existing
  `ForEach(model.categories, id: \.self)` producing each category `Label`
  (`.tag(SidebarSelection.category(category))`). Keep the existing `icon(for:)`
  mapping and column-width / navigation-title modifiers unchanged.
- Revise the doc comment to describe the column as a flat list of Themes plus
  option categories (R3/R6 references stay accurate).

**Patterns to follow:** The existing `List(selection:)` + `Label(...).tag(...)`
rows in `SidebarView` — reuse them verbatim, only removing the `Section`
wrappers.

**Test scenarios:** Test expectation: none — SwiftUI view-only change in the
app target, which has no test harness. Verified by build + launch.

**Verification:** App builds and launches; the sidebar shows Themes followed by
the category rows with **no** "Appearance" or "Categories" (or "Discover")
section headers; selecting Themes or any category still shows the same content
as before.

---

## Scope Boundaries

**In scope:**
- Adding the Customized top-bar control and removing its sidebar row (U1).
- Removing the three sidebar section headers and flattening the list (U2).

**Out of scope / non-goals:**
- Any change to `SidebarSelection`, `AppModel` selection logic, content routing,
  or anything in `GhosttyConfigKit`.
- Re-grouping the flat list under different headers or adding dividers — the
  request is explicitly a flat list.
- Changing the Themes or Problems entry points, the version chip, or the
  health chip behavior.
- Visual redesign of the sidebar rows themselves (icons, spacing) beyond
  removing section headers.

### Deferred to Follow-Up Work

- None.

---

## Verification (whole plan)

1. `swift build` succeeds with no new warnings in the two touched files.
2. `swift run GhosttyConfigEditor` launches the app.
3. Top bar shows a "Customized" control next to the version and health chips;
   clicking it switches the middle column to the customized-options view and the
   control reflects its active state.
4. The sidebar renders Themes + the option categories as a flat list with no
   "Discover" / "Appearance" / "Categories" headers, and selecting any row shows
   the same content it did before.

Note: there are no automated tests for these units — the app target has no test
harness by design (logic and its tests live in `GhosttyConfigKit`, which is
untouched here).
