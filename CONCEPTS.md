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
An at-a-glance severity classification derived from a `LintReport`: `.clean` (no actionable issues), `.warning` (at least one non-`.info` footgun), `.error` (live validation failed), or `.unknown` (validation could not run *and* nothing else is actionable). Severity precedence is error > warning > unknown: because footgun lint is static (it doesn't need the validation binary), an actionable footgun still surfaces as `.warning` even when `ghostty +validate-config` couldn't run. Surfaced in the window's top-bar health chip, which opens the Problems surface when clicked. Distinct from the Problems list's own clean check, which also surfaces `.info`-only findings that Config Health deliberately excludes from its count.

## Apply & Reload

### Auto-Reload
After a successful in-app config write — an option apply, a theme apply, or an undo — the app signals the running Ghostty GUI process(es) to reload their configuration, so live terminals reflect the change immediately instead of waiting for a manual reload.

The signal is POSIX `SIGUSR2` (Ghostty's macOS config-reload signal, available 1.2.0+), sent to every process discovered by bundle id `com.mitchellh.ghostty` (not by process name, which would match the short-lived `ghostty +…` CLI subprocesses the app itself spawns). It is *best-effort and version-gated*: a missing, unreachable, or unsupported Ghostty never turns a successful save into a failure, and a Ghostty older than 1.2.0 is never signaled (the signal would terminate a build without the reload handler). On by default, with a user toggle to disable it. Because the signal is one-way, the app reports that it *asked* Ghostty to reload rather than confirming the reload succeeded.
