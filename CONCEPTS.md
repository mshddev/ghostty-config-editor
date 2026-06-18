# Concepts

> Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Catalog

### Option Catalog
The full set of Ghostty configuration options the app presents to the user, each with its documentation, default value, the user's current value, and a category.

It is *self-describing*: generated at runtime from the installed Ghostty binary's own configuration dump rather than a hand-maintained list, so it always reflects whatever Ghostty version is installed. It is also *macOS-scoped*: options that only take effect on Linux/GTK/Wayland/X11 are filtered out, so the catalog only ever presents options that can actually affect macOS.

### Catalog Option
A single entry in the Option Catalog: one configuration key together with its documentation, default value(s), inferred value type, accepted or enumerated values where known, whether it is repeatable, and the category it belongs to.

## Lint & Health

### Config Health
An at-a-glance severity classification derived from a `LintReport`: `.clean` (no actionable issues), `.warning` (at least one non-`.info` footgun), `.error` (live validation failed), or `.unknown` (validation could not run). Surfaced in the window's top-bar health chip, which opens the Problems surface when clicked. Distinct from the Problems list's own clean check, which also surfaces `.info`-only findings that Config Health deliberately excludes from its count.
