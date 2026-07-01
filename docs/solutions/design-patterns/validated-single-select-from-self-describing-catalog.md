---
title: Detect finite-value config options at the parser choke point and render a validated single-select
date: 2026-06-30
category: design-patterns
module: GhosttyConfigKit
problem_type: design_pattern
component: tooling
severity: medium
applies_when:
  - "A catalog is derived at runtime by parsing CLI/tool output (self-describing options)"
  - "Some options carry a known finite set of valid values while others are open-valued"
  - "The editor UI uses a single-select control (e.g. SwiftUI Picker) keyed on a draft value"
  - "The UI-framework target has no test harness, so choice-resolution logic must live in a tested layer"
  - "Value-type must be inferred from human-readable doc prose rather than a structured type flag"
related_components:
  - "Sources/GhosttyConfigKit/Catalog/CatalogParser.swift"
  - "Sources/GhosttyConfigKit/Config/ConfigReader.swift"
  - "Sources/GhosttyConfigManager/Views/OptionDetailView.swift"
tags:
  - self-describing-catalog
  - cli-derived-options
  - value-type-inference
  - single-select-dropdown
  - swiftui-picker
  - parser-choke-point
  - enum-detection
  - ghostty
---

# Detect finite-value config options at the parser choke point and render a validated single-select

## Context

GhosttyConfigManager is a native macOS SwiftUI editor for Ghostty's config. Its option catalog is **self-describing**: at runtime it parses `ghostty +show-config --default --docs` into a catalog, so the app stays correct across Ghostty versions without a hand-maintained schema. The editor already rendered a SwiftUI `Picker` for any option typed `.enumeration` — the gap being closed was **detection**: deciding *which* options have a known, finite, single-select value set, and producing a dropdown whose rows are both complete (no legal value missing) and safe (no value silently dropped).

That gap turned out to sit on top of a quieter SwiftUI failure mode. A `Picker(selection:)` whose bound selection has no matching row tag renders blank and, on the next interaction, overwrites the user's real value — silent data loss. So the work spans two layers that are easy to conflate: a **kit-side detection-and-resolution** layer (pure, unit-tested) and a **view** layer that must be a thin, dumb consumer of it. The architecture forces this split: the kit target (`GhosttyConfigKit`) has XCTest; the SwiftUI app target has **no test harness** *(auto memory [claude]: SPM kit/app split — pure logic belongs in the kit, which is tested; the app target is not)*.

## Guidance

**1. Resolve the selection in the kit so the bound value always has a matching tag.** Never hand a SwiftUI `Picker` a list of raw values and hope the seeded selection is among them. Compute the rows in a pure function that *guarantees* a row whose `tag` equals the seeded selection. In this codebase that's `MergedOption.enumChoices(current:)`: it returns `enumValues` in documented order, and when `current` is empty or outside the set it **prepends** a synthetic row carrying `current` as its tag — labelled `"<value> — current value"` for a saved out-of-enum value, or `"Not set — uses default (<default>)"` for an unset option whose default isn't listed (tag is the empty string for empty-default options like `macos-option-as-alt`). The view then can't desync.

**2. Seed the picker from the SAVED value, never the in-progress draft.** The view passes its `currentValue` (saved), not `draft`. Passing `draft` makes the synthetic out-of-enum row vanish the instant the selection moves off it — the row only exists because `current` isn't in the set, so recomputing it against a now-changed `draft` deletes it mid-interaction. Seeding from the saved value also preserves "an unchanged Apply leaves the config byte-for-byte unchanged."

**3. Detect at the single parser choke point, never per UI surface.** All value-type and enum decisions happen once, in `CatalogParser.parse` (via `resolvedEnumValues` / `inferType`). The view branches only on `valueType` and consumes `enumChoices` / `enumValues`. No UI surface re-inspects doc prose.

**4. Guard on the value literal, not the option name.** To suppress enumeration for color options, test whether the **default value** starts with `#` — not whether the name contains "color." Three real options (`window-padding-color`, `window-colorspace`, `osc-color-report-format`) carry "color" in their name yet enumerate genuine closed sets; a name-based guard regresses all three.

**5. A comma in the default means composite, not enum.** A default like `bell-features = no-system,no-audio,attention,title,no-border` combines flags. Its flags *are* documented under "Valid values," so naive detection would build a single-select dropdown that drops every other flag on edit. Guard: comma in default leads to free text. *(This trap was caught by an adversarial Swift code review, not by the plan.)*

**6. Read the whole comma-run in doc bullets, not the first token.** Ghostty co-lists choices on one bullet (`` * `bash`, `elvish`, `zsh` - description ``) and wraps them onto continuation lines. Reading only the first backtick token renders a *closed dropdown missing legal values* — the inverse data-loss bug. Read the leading run of backtick tokens, stop at the first prose / `` - ``, and follow a trailing dangling comma onto the next line.

**7. Force open-valued options to free text.** Options that document a finite set *and* accept values beyond it (`window-decoration` also takes `true`/`false`; `background-blur` takes any integer) keep their documented values for a read-only reference badge but are typed `.string`. Letting `inferType` run on `background-blur`'s `false` default would mis-infer `.boolean` and render a toggle.

**8. Keep a small, version-pinned curated map for prose-only impostors.** A few options express extra states only in prose (`confirm-close-surface` adds `always`; `macos-option-as-alt` adds `left`/`right`). These get a narrow fallback map, explicitly re-audited on Ghostty upgrade — the deliberate exception to the self-describing rule.

**9. Filter inert values per-value, then re-apply the floor.** Platform scoping (`MacOSCatalogScope`) drops whole *options*; it can't drop individual Linux-only values like `window-theme = ghostty`. A curated per-value map handles that, and the "≥2 real values" floor is re-applied *after* filtering so a set that collapses to one value renders nothing instead of a degenerate one-item dropdown.

## Why This Matters

- **Silent data loss is the worst failure class.** Both the blank-picker overwrite and the dropped-flag composite edit destroy user config without an error. They pass a smoke test (the control renders) and only bite on the second interaction or on save.
- **The trap is symmetric.** A guard that's too eager produces a *closed dropdown missing legal values* (user can't pick a value Ghostty accepts); a guard that's too lax produces a dropdown that *drops* values. Both are data-integrity bugs; the detection logic has to thread between them.
- **Untestable layers must stay thin.** Because the SwiftUI target has no harness, any logic left in the view is effectively unverifiable. Pushing selection resolution into the kit turns a UI footgun into six fast unit tests (in-set / out-of-set / unset-listed-default / unset-empty-default / no-duplicate-row), and lets the view be a consumer you can read and trust at a glance.
- **Name-based heuristics rot against real data.** Every shortcut that keys off an option's *name* ("has 'color' in it," "has 'decoration' in it") was wrong against actual Ghostty 1.3.1 output. Keying off the value literal and the documented structure survives contact with reality.

## When to Apply

- You're binding a SwiftUI `Picker` (or any single-select control) whose selection is seeded from persisted or external data that **might not be in the option list** — out-of-range saved values, an unset state, a value from a newer schema version.
- You're inferring a control type from *self-describing* / parsed metadata (CLI `--docs`, JSON schema, OpenAPI, DB introspection) rather than a hand-written schema.
- A "finite value set" might actually be a **composite** (flags combined with commas/pipes) or **open** (documented examples plus arbitrary input).
- The logic lives in a target with no test harness (a SwiftUI view, a thin shell) and could instead live in a tested layer.
- You're tempted to branch on a **name** ("if the field is called `color`…") instead of on the **value** or **structure**.

## Examples

### (1) Unsafe vs safe Picker binding

**Before — unsafe.** The picker is fed raw `enumValues`; if the saved value isn't among them, the selection has no matching tag, renders blank, and overwrites on next interaction:

```swift
// Saved value "always" is NOT in enumValues ["true","false"] -> blank picker,
// and the next menu interaction silently writes a listed value over "always".
Picker("Value", selection: $draft) {
    ForEach(option.option.enumValues, id: \.self) { value in
        Text(value).tag(value)
    }
}
```

**After — safe.** Rows come from the kit resolver, seeded from the *saved* value, guaranteeing a matching tag (`Sources/GhosttyConfigManager/Views/OptionDetailView.swift`):

```swift
case .enumeration:
    // Rows come from the kit helper (not raw enumValues) so a saved
    // out-of-enum value stays selectable and is never silently dropped.
    // Seed from `currentValue` (the saved value), never `draft`.
    Picker("Value", selection: $draft) {
        ForEach(option.enumChoices(current: currentValue)) { choice in
            Text(choice.label).tag(choice.value)
        }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .fixedSize()
```

The guarantee lives in the tested kit (`Sources/GhosttyConfigKit/Config/ConfigReader.swift`):

```swift
func enumChoices(current: String) -> [EnumChoice] {
    let values = option.enumValues
    if !current.isEmpty, values.contains(current) {
        // Saved value is a listed choice — just mark it selected.
        return values.map { EnumChoice(value: $0, label: $0, isSelected: $0 == current) }
    }
    // current is empty or outside the set: lead with a row carrying it as the
    // tag, so the seeded selection always has a match.
    let leadLabel: String
    if isSet {
        leadLabel = "\(current) — current value"
    } else {
        let def = option.defaultValue
        leadLabel = def.isEmpty ? "Not set — uses default" : "Not set — uses default (\(def))"
    }
    let lead = EnumChoice(value: current, label: leadLabel, isSelected: true)
    return [lead] + values.map { EnumChoice(value: $0, label: $0, isSelected: false) }
}
```

### (2) Value-literal, not name-based, color guard

**Before — name-based (regresses three real options).** Suppressing enumeration by name kills `window-padding-color`, `window-colorspace`, and `osc-color-report-format`, which all enumerate genuine closed sets:

```swift
// WRONG: a name-based guard. window-colorspace = "srgb" has a closed set
// ("srgb","display-p3") but this returns [] and drops the dropdown.
func resolvedEnumValues(name: String, default def: String, documentation: String) -> [String] {
    if name.lowercased().contains("color") { return [] }   // regression
    return extractEnumValues(documentation)
}
```

**After — value-literal (`Sources/GhosttyConfigKit/Catalog/CatalogParser.swift`).** Only a `#`-prefixed default (a real color literal like `search-foreground = #000000`) suppresses enumeration; the comma-default composite guard sits right beside it:

```swift
func resolvedEnumValues(name: String, default def: String, documentation: String) -> [String] {
    // A literal-color default (#RRGGBB) means any "Valid values" are format
    // placeholders, not a closed set. Guard on the *value*, not the name:
    // window-padding-color / window-colorspace / osc-color-report-format all
    // carry "color" in their name yet enumerate a genuine closed set.
    if def.hasPrefix("#") { return [] }
    // A comma-separated default marks a composite multi-flag value
    // (bell-features = no-system,no-audio,…) — single-select would drop flags.
    if def.contains(",") { return [] }

    let parsed = extractEnumValues(documentation)
    let documented = parsed.isEmpty ? (curatedEnumValues[name] ?? []) : parsed
    let scoped = macOSInertEnumValues[name].map { inert in
        documented.filter { !inert.contains($0) }
    } ?? documented
    // Re-apply the ≥2 floor AFTER inert filtering, so a set that collapses to
    // one macOS-relevant value renders nothing, not a one-item dropdown.
    return scoped.count >= 2 ? scoped : []
}
```

## Related

- Sibling pattern (same module, complementary problem): `docs/solutions/design-patterns/platform-scoping-cli-derived-option-catalog.md` — scoping the catalog by excluding whole Linux/GTK-only *options*. This doc extends the same "derive from doc prose at one parser choke point, version-pin curated lists, prefer value/structure over name" philosophy to *value-type detection* and adds the missing **per-value** inert filter the sibling explicitly did not cover (it filters options, not individual enum values).
- Plan: `docs/plans/2026-06-30-003-feat-option-value-dropdowns-plan.md` — the implementation plan, including the two resolved open questions (open-valued options kept free-text; macOS-inert enum values filtered).
- Origin requirements: `docs/brainstorms/2026-06-16-ghostty-config-manager-requirements.md` — R2 (surface accepted/enumerated values) and R13 (type-appropriate controls rather than raw text entry).
