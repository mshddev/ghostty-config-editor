# Contributing

Thanks for your interest in improving Ghostty Config Editor! Contributions of all kinds are
welcome — bug reports, feature ideas, documentation, and code.

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md) — please be kind and respectful. To
report a security issue, see [SECURITY.md](SECURITY.md).

## Getting set up

You'll need Xcode 26 (the macOS 26 SDK) and a Swift 6 toolchain to build, macOS 14+ to run, and
[Ghostty](https://ghostty.org) installed — the app and some tests drive the real `ghostty` CLI. The
macOS 26 SDK is required because the app adopts a couple of macOS 26 SwiftUI refinements behind
`#available` guards; the app itself still runs back to macOS 14.

```bash
git clone https://github.com/mshddev/ghostty-config-editor.git
cd ghostty-config-editor
swift build
swift test
swift run GhosttyConfigEditor
```

## Project layout

- **`Sources/GhosttyConfigKit`** — all the non-UI logic (CLI, option catalog, config read/write,
  lint, search, themes). This is where most behavior lives, and it's fully unit-tested.
- **`Sources/GhosttyConfigEditor`** — a thin SwiftUI shell over the kit.
- **`Tests`** — unit tests, grounded in real captured Ghostty CLI output under `Fixtures/`.

Keeping logic in the kit (not the views) is deliberate: it means new behavior can be covered by a
plain `swift test` rather than UI testing.

## Making a change

1. Fork and create a branch.
2. Keep the change focused; match the surrounding code's style and comment density.
3. **Run `swift test`** — the full suite must pass. CI runs it on every push and pull request.
4. If you touch behavior in the kit, add or update a test for it.
5. Open a pull request describing what changed and why.

## Reporting bugs

Open an issue with your macOS version, your `ghostty +version`, and steps to reproduce. If the app
showed an error, include its text.

## Scope

This app intentionally does one thing: give Ghostty's configuration a safe, native GUI. It reads and
writes your local config and drives your installed `ghostty` binary — it doesn't reimplement Ghostty's
option parsing or ship its own copy of the options list. Proposals that keep that boundary are the
easiest to accept.
