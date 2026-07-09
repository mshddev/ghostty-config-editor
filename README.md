# Ghostty Config Editor

> A native macOS app that gives the [Ghostty](https://ghostty.org) terminal a friendly GUI for its configuration.

[![CI](https://github.com/mshddev/GhosttyConfigEditor/actions/workflows/ci.yml/badge.svg)](https://github.com/mshddev/GhosttyConfigEditor/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-f05138?logo=swift&logoColor=white)

Ghostty is configured through a text file. This app puts a real UI on top of it: **browse every
option with its official documentation, search by intent, edit safely with validate-before-write,
and preview and apply themes** — without leaving your editor open to a syntax mistake.

It reads your real config at `~/.config/ghostty/config` and drives the local `ghostty` CLI
(`+show-config`, `+list-themes`, `+validate-config`, …), so it always reflects the exact Ghostty
version you have installed — no bundled, drifting copy of the options list.

## Features

- **Every option, documented** — the full Ghostty option catalog, each with its description, default,
  and your current value, grouped into readable categories.
- **Edit safely** — changes are validated with `ghostty +validate-config` *before* they touch your
  file. Invalid values are rejected with a clear message; your working config is never left broken.
- **Search by intent** — type what you want ("cursor blink", "transparency") and find the option,
  even if you don't know its exact key.
- **Themes** — browse the built-in themes as live previews and apply one in a click.
- **Keyboard shortcuts editor** — see and rebind Ghostty keybindings, filtered by group, with
  press-the-keys capture.
- **Live reload** — optionally asks Ghostty to reload its config the moment you save.
- **Native and honest** — a real SwiftUI Mac app that only ever edits the file you'd edit by hand.

## Install

### Download

Grab the latest `Ghostty Config Editor.app` from the [Releases](https://github.com/mshddev/GhosttyConfigEditor/releases)
page, unzip it, and drag it to `/Applications`.

> **First launch:** the app is signed ad-hoc, so macOS Gatekeeper may say it's from an
> "unidentified developer." Right-click the app → **Open** → **Open** once, and macOS will
> remember your choice from then on.

### Build from source

```bash
git clone https://github.com/mshddev/GhosttyConfigEditor.git
cd GhosttyConfigEditor
scripts/package-app.sh --install   # builds and copies the .app to /Applications
```

## Requirements

- macOS 14 (Sonoma) or newer
- **[Ghostty](https://ghostty.org) 1.3.1 or newer** — the version the option catalog and test
  fixtures are built and verified against. The app reads options live from your installed `ghostty`,
  so newer releases work too; much older ones are untested. The app locates the binary via the app
  bundle, Homebrew, or your login shell.
- To build: Swift 6 toolchain / Xcode 16+

## Build, test, run (development)

This is a Swift Package, not an `.xcodeproj`:

```bash
swift build                      # debug build
swift test                       # run the test suite
swift run GhosttyConfigEditor    # launch the app
```

To work in Xcode: `xed .`, then select the **GhosttyConfigEditor** scheme, destination **My Mac**,
and press ⌘R. (macOS apps run natively — there is no simulator.)

### Project layout

- **`GhosttyConfigKit`** — library target with all the logic (CLI, catalog, config read/write, lint,
  search, themes). Fully unit-tested.
- **`GhosttyConfigEditor`** — thin SwiftUI executable shell over the kit.
- **Tests** — grounded in real captured Ghostty CLI output.

### Packaging

`scripts/package-app.sh` builds a release binary, assembles the `.app` bundle (binary + resources +
`Info.plist`), and ad-hoc code-signs it so Gatekeeper allows a local launch. The app is intentionally
**not sandboxed** — it execs your local `ghostty` and reads `~/.config`, neither of which a sandboxed
app could reach. To give it an icon, drop an `AppIcon.icns` at `packaging/AppIcon.icns` before running
the script.

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a PR — CI runs the full
suite on every push.

## License

[MIT](LICENSE) © 2026 mshddev.

## Disclaimer

This is an **unofficial**, community-built tool. It is not affiliated with, endorsed by, or sponsored
by the Ghostty project or its authors. "Ghostty" and the Ghostty logo are the property of their
respective owners. This app only reads and writes your local Ghostty configuration and invokes your
locally installed `ghostty` binary.
