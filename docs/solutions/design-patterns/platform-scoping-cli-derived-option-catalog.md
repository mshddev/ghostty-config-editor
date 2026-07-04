---
title: Scope a CLI-derived option catalog to one platform with a curated exclusion list
date: 2026-06-17
category: design-patterns
module: GhosttyConfigKit
problem_type: design_pattern
component: tooling
severity: medium
applies_when:
  - "A catalog is derived at runtime by parsing CLI/tool output (self-describing options)"
  - "The app targets a subset of the platforms the underlying tool supports"
  - "Platform applicability lives only in human-readable doc prose, not a structured flag"
  - "A name-prefix heuristic is being considered to filter the out-of-scope subset"
  - "Multiple UI surfaces read from the same catalog"
related_components:
  - "Sources/GhosttyConfigKit/Catalog/OptionCatalog.swift"
  - "Sources/GhosttyConfigKit/Catalog/CatalogParser.swift"
tags:
  - platform-filtering
  - self-describing-catalog
  - cli-derived-options
  - curated-exclusion
  - parser-design
  - macos-scoping
  - option-catalog
  - ghostty
---

# Scope a CLI-derived option catalog to one platform with a curated exclusion list

## Context

GhosttyConfigEditor is a macOS-only SwiftUI app whose option catalog is entirely **self-describing**: it is generated at runtime by parsing `ghostty +show-config --default --docs`, the installed binary's own output. That output is platform-agnostic — Ghostty is cross-platform (macOS + Linux/GTK), and `+show-config` emits every config option regardless of the platform you run it on. So roughly two dozen options that only take effect on Linux/GTK/Wayland/X11 flow into the parsed catalog unchanged and pollute every discovery surface: the sidebar category list, full-text search, the All Options browser, and the "Not Using Yet" surface that recommends options the user hasn't set. A macOS user would be prompted to try `window-titlebar-background`, `gtk-tabs-location`, or `class` — options with zero effect on macOS. The root gap: the source carries no machine-readable platform tag, so nothing in a naive parse keeps inert options out.

## Guidance

**(a) Derive the exclusion set from each option's own doc prose — not from the option name alone.**

The CLI output's doc-comment blocks contain human-readable platform-restriction sentences: "GTK only.", "This only affects GTK builds.", "macOS uses CoreText and does not have an equivalent configuration.", "Currently only supported in the GTK app runtime." Those sentences are the authoritative signal. Any exclusion logic that ignores them and operates only on the name is wrong at the edges in both directions.

**(b) Encode it as a curated two-part list.**

- A **prefix rule** for the unambiguous Linux-stack families: any option whose name begins with `gtk-`, `x11-`, `linux-`, or `wayland-`. These prefixes are structural and stable.
- An **explicit, hand-maintained set** for the doc-confirmed Linux/GTK/Wayland-only options that do *not* carry one of those prefixes. Each entry is annotated with the doc sentence that establishes it, and the list is a version-pinned snapshot to re-audit on tool upgrades.

```swift
public enum MacOSCatalogScope {

    private static let linuxStackPrefixes: [String] = ["gtk-", "x11-", "linux-", "wayland-"]

    /// Doc-confirmed Linux/GTK/Wayland-only options that lack a Linux-stack prefix.
    /// Each is annotated with the --docs sentence that establishes it.
    private static let nonPrefixedLinuxOnly: Set<String> = [
        "language",                              // "GTK only."
        "async-backend",                         // "only supported on Linux ... On macOS, we always use `kqueue`."
        "quit-after-last-window-closed-delay",   // "Only implemented on Linux."
        "window-show-tab-bar",                   // "Currently only supported on Linux (GTK)."
        "window-subtitle",                       // "This feature is only supported on GTK."
        "app-notifications",                     // "This configuration only applies to GTK."
        "quick-terminal-keyboard-interactivity", // "Only has an effect on Linux Wayland."
        "class",                                 // "This only affects GTK builds."
        "freetype-load-flags",                   // "macOS uses CoreText and does not have an equivalent configuration."
        "window-titlebar-background",            // "Currently only supported in the GTK app runtime."
        "window-titlebar-foreground",            // "Currently only supported in the GTK app runtime."
    ]

    public static func excludes(_ name: String) -> Bool {
        if linuxStackPrefixes.contains(where: name.hasPrefix) { return true }
        return nonPrefixedLinuxOnly.contains(name)
    }
}
```

**(c) Apply it at the single catalog-build choke point — the parser.**

```swift
let options = order.compactMap { name -> CatalogOption? in
    guard let b = builders[name] else { return nil }
    // macOS-scoped catalog: drop options that only take effect on Linux/GTK.
    guard !MacOSCatalogScope.excludes(name) else { return nil }
    // ... build CatalogOption ...
}
```

Because the catalog is the single source every downstream surface reads from, one `guard` at parse time is enough — there is no per-surface filtering to maintain, and a future surface cannot accidentally expose a filtered option unless it bypasses the catalog entirely.

**(d) Re-home any kept option the categorizer would mis-file.** When a genuinely cross-platform option's prefix would land it in the now-always-empty "Linux / GTK" category, redirect it. `desktop-notifications` is the case: `desktop-` is deliberately absent from the prefix map, and a name override routes it to "Terminal".

## Why This Matters

**The prefix heuristic cannot be made structurally correct**, because the CLI output has no machine-readable platform field — applicability lives only in doc prose. So a prefix filter fails at both edges at once:

- **False positive (over-exclusion):** `desktop-notifications` starts with `desktop-`, which a "drop anything Linux-looking" rule might catch — but its OSC 9 / OSC 777 escape sequences work on macOS, so excluding it hides a useful option.
- **False negatives (under-exclusion):** `class`, `freetype-load-flags`, `window-titlebar-background`, and `window-titlebar-foreground` carry no Linux-stack prefix, so a prefix-only filter passes them straight into the catalog, where "Not Using Yet" recommends changes that do nothing on macOS.

These are real entries in Ghostty 1.3.x output, not hypotheticals. Applying the filter at the parser choke point then makes the guarantee propagate to every surface for free.

## When to Apply

- A catalog is derived from a CLI tool, plugin manifest, API schema, or registry, and you need to scope it to a subset — by platform, plan tier, feature flag, or role.
- The source does **not** structurally tag that subset (no machine-readable field distinguishing in-scope from out-of-scope).
- Subset membership is expressed only in human-readable prose (doc comments, README notes, informal convention).
- Multiple downstream surfaces consume the catalog and would each have to replicate the filter if it were not applied at the source.

In those circumstances: read the prose, curate a doc-annotated list, apply it once at catalog build, and version-pin the list to the source you read it from.

## Examples

**Before — naive prefix filter (wrong both ways):**

```swift
// Drops desktop-notifications (cross-platform); leaks class / window-titlebar-* (GTK-only, no prefix)
private static let linuxPrefixes = ["gtk-", "x11-", "linux-", "wayland-", "desktop-"]
static func excludes(_ name: String) -> Bool { linuxPrefixes.contains(where: name.hasPrefix) }
```

**After — curated, doc-evidence-derived:** the prefix rule drops the obvious families; the explicit set catches the 11 non-prefixed GTK/Linux-only options; `desktop-notifications` is kept (no `desktop-` prefix, not in the set). See the `MacOSCatalogScope` block above.

**The process lesson — the curated list was incomplete across three verification passes.** The exclusion count grew **17 → 25 → 27** because regex scans of the CLI output missed entries whose restriction sentence is **line-wrapped** across doc-comment lines. For example:

```
# Background color for the window titlebar. This only takes effect if
# window-theme is set to ghostty. Currently only supported in the GTK app
# runtime.
```

A regex searching for "GTK app runtime" as a unit never matches — "GTK app" ends one line and "runtime." begins the next. The fix: **whitespace-normalize the full doc block** (collapse newlines to spaces) before scanning, and do a final **adversarial manual read** of every option whose docs mention "GTK", "Linux", "Wayland", "X11", or "CoreText", regardless of whether the regex fired. Independent reviewers reading the raw `--docs` found the leaks that automated scans missed.

**Operational consequence:** treat the curated list as a version-pinned snapshot tied to the tool release it was read from (Ghostty 1.3.x here), and add a re-audit step to the upgrade checklist — new config keys arrive with or without prefixes, and the only reliable oracle is reading the new `--docs` output adversarially.

## Related

- Decision record: `docs/brainstorms/2026-06-16-ghostty-config-manager-requirements.md` — the "macOS-scoped catalog" Key Decision this pattern implements (R1, R6).
- Implementation: PR #2 `feat(catalog): scope the option catalog to macOS` (merged 2026-06-17) — introduced `MacOSCatalogScope`; the curated list converged 17 → 25 → 27 excluded options across adversarial review passes (200 → 173 options for the 1.3.x fixture).
- Adjacent (different problem, same module): `docs/solutions/logic-errors/directory-walk-infinite-loop-at-filesystem-root.md` — the CI/test-suite hang on the login-shell probe / live integration tests; relevant when a `GhosttyConfigKit` test that execs `ghostty` hangs.
