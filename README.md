# Ghostty Config Editor

> An unofficial, native macOS app for editing your [Ghostty](https://ghostty.org) config.

[![CI](https://github.com/mshddev/ghostty-config-editor/actions/workflows/ci.yml/badge.svg)](https://github.com/mshddev/ghostty-config-editor/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-f05138?logo=swift&logoColor=white)

Ghostty is configured through a plain text file — which is fine, right up until you're digging
through the docs for the exact option name, or you save one typo and the terminal won't start. So
this app puts a small UI on top of that file: browse every option with its official docs, search by
what you actually want, edit with validate-before-write, and preview a theme before you commit to it.

It doesn't reimplement anything. It reads your real config at `~/.config/ghostty/config.ghostty`
(or the pre-1.3 `config`) and drives your local `ghostty` CLI — `+show-config`, `+list-themes`,
`+validate-config`, and the rest — so what you see always matches the exact Ghostty you have
installed. No bundled options list quietly drifting out of date.

## Features

- **Every option, documented** — the full Ghostty option catalog, each with its description, default,
  and your current value, grouped into categories you can actually scan.
- **Edit safely** — every change is checked with `ghostty +validate-config` *before* it touches your
  file. A bad value is rejected with a clear message, so your working config never ends up broken.
- **Search by intent** — type what you're after ("cursor blink", "transparency") and find the option,
  even when you don't know its exact key.
- **Themes** — browse the built-in themes as live previews and apply one in a click.
- **Keyboard shortcuts** — see and rebind Ghostty's keybindings, filtered by group, with
  press-the-keys capture.
- **Live reload** — optionally, it asks Ghostty to reload the moment you save, so your open terminals
  update right away.
- **Open from Ghostty (⌘,)** — Ghostty opens its config with whatever app is the default editor for
  `.ghostty` files, and this app claims that role. Set it up once in **Status** (⌘,) — rename a
  pre-1.3 `config` to `config.ghostty` if needed, then click **Use This App** — and Ghostty's
  Open Config lands here instead of TextEdit.
- **Native, and honest about it** — a real SwiftUI Mac app that only ever edits the file you'd edit
  by hand. Nothing more.

## Install

### Download

Grab the latest `Ghostty Config Editor.app` from the [Releases](https://github.com/mshddev/ghostty-config-editor/releases)
page, unzip it, and drag it into `/Applications`.

> [!NOTE]
> **First launch — the "Apple could not verify…" block.** The app is ad-hoc signed and not
> notarized, so on first open macOS Gatekeeper blocks it once. Clear it either way (just once —
> macOS remembers afterward):
>
> - **System Settings:** double-click the app, click **Done** on the warning, then open
>   **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway**
>   next to the app's name. On macOS 15 (Sequoia) / 26 (Tahoe) this is the reliable route —
>   the older right-click → **Open** trick no longer works dependably.
> - **Terminal (fastest):** remove the download quarantine, then open normally:
>   ```bash
>   xattr -dr com.apple.quarantine "/Applications/GhosttyConfigEditor.app"
>   ```

### Build from source

```bash
git clone https://github.com/mshddev/ghostty-config-editor.git
cd ghostty-config-editor
scripts/package-app.sh --install   # build, then copy the .app into /Applications
```

## Requirements

- **To run:** macOS 14 (Sonoma) or newer.
- **[Ghostty](https://ghostty.org) 1.3.1 or newer** — the version the option catalog and test
  fixtures are built and verified against. The catalog is read live from your installed `ghostty`, so
  newer releases work too; much older ones are untested. The app finds the binary via the app bundle,
  Homebrew, or your login shell.
- **To build from source:** Xcode 26 (the macOS 26 SDK) and a Swift 6 toolchain. The app adopts a
  couple of macOS 26 SwiftUI refinements behind `#available` guards — those only *compile* against the
  macOS 26 SDK, even though the app itself still runs all the way back to macOS 14.

## Build, Test, Run (development)

It's a Swift Package, not an `.xcodeproj`:

```bash
swift build                      # debug build
swift test                       # run the suite
swift run GhosttyConfigEditor    # launch it
```

Prefer Xcode? `xed .`, pick the **GhosttyConfigEditor** scheme with **My Mac** as the destination,
and ⌘R. (Mac apps run natively — there's no simulator.)

### Project layout

- **`GhosttyConfigKit`** — the library target, where all the logic lives (CLI, catalog, config
  read/write, lint, search, themes). Fully unit-tested.
- **`GhosttyConfigEditor`** — a thin SwiftUI shell over the kit.
- **Tests** — grounded in real captured `ghostty` CLI output, not hand-waved mocks.

### Packaging

`scripts/package-app.sh` builds a release binary, assembles the `.app` (binary + resources +
`Info.plist`), and ad-hoc code-signs it so Gatekeeper allows a local launch. The app is deliberately
**not sandboxed** — it execs your local `ghostty` and reads `~/.config`, and a sandboxed app could
reach neither. Drop an `AppIcon.icns` at `packaging/AppIcon.icns` before running the script to embed
an icon.

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening one — CI runs the full
suite on every push, and if you touch behavior in the kit, add or update a test for it.

And if you find it useful, please consider giving it a star — it helps more people find it. Feel free
to contribute.

## License

[MIT](LICENSE) © 2026 mshddev.

## Disclaimer

This is an **unofficial**, community-built tool — not affiliated with, endorsed by, or sponsored by
the Ghostty project or its authors. "Ghostty" and the Ghostty logo belong to their respective owners.
The app only reads and writes your local Ghostty config and invokes your locally installed `ghostty`
binary. Nothing leaves your machine.
