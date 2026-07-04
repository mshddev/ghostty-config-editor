# Ghostty Config Editor

> An unofficial config editor for Ghostty.

A native macOS app (SwiftUI) that gives the [Ghostty](https://ghostty.org) terminal a GUI for
managing its configuration — browse every option with its docs, search by intent, edit safely with
validate-before-write, and preview/apply themes.

It reads your real config at `~/.config/ghostty/config` (or `config.ghostty`) and drives the local
`ghostty` CLI (`+show-config`, `+list-themes`, `+validate-config`, …) — so it always reflects the
Ghostty version you actually have installed.

## Requirements

- macOS 14 (Sonoma) or newer
- [Ghostty](https://ghostty.org) installed (the app locates it via the app bundle, Homebrew, or your
  login shell)
- Swift 6 toolchain / Xcode 16+ to build from source

## Project layout

This is a Swift Package, not an `.xcodeproj`:

- `GhosttyConfigKit` — library target with all the logic (CLI, catalog, config read/write, lint,
  search, themes). Fully unit-tested.
- `GhosttyConfigEditor` — thin SwiftUI executable shell.
- `GhosttyConfigKitTests` — tests, grounded in real captured Ghostty CLI output.

## Build, test, run

```bash
swift build            # debug build
swift test             # run the test suite
swift run GhosttyConfigEditor   # launch the app
```

To work in Xcode: `xed .` then select the **GhosttyConfigEditor** scheme, destination **My Mac**,
and press ⌘R. (macOS apps run natively — there is no simulator.)

## Package a double-clickable app

To produce a self-contained `.app` you can launch from Spotlight or the Dock without the terminal:

```bash
scripts/package-app.sh             # builds dist/GhosttyConfigEditor.app
scripts/package-app.sh --install   # also copies it to /Applications
```

The script builds a release binary, assembles the bundle (binary + resources + `Info.plist`), and
ad-hoc code-signs it so Gatekeeper allows local launch. The app is intentionally **not** sandboxed —
it execs your local `ghostty` and reads `~/.config`, neither of which a sandboxed app could reach.

To give it an icon, drop an `AppIcon.icns` at `packaging/AppIcon.icns` before running the script.
