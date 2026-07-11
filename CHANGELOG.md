# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

## [0.1.0] — Initial release

First public release. A native macOS (SwiftUI) GUI for the Ghostty terminal's configuration.

### Added
- Browse the full Ghostty option catalog with inline official documentation, defaults, and your
  current values, grouped into readable categories.
- Validate-before-write editing: changes are checked with `ghostty +validate-config` before they
  touch your file, so an invalid value is rejected instead of breaking your config.
- Intent-based search across options.
- Theme browser with live previews and one-click apply.
- Keyboard-shortcuts editor with group filtering and press-the-keys capture.
- Optional live reload — signals the running Ghostty to reload its config on save (Ghostty 1.2+).
- **Open from Ghostty (⌘,)**: the packaged app declares the `.ghostty` file type and registers as
  an editor for it, so Ghostty's Open Config command (which launches the default editor for the
  config file's extension, Ghostty ≥ 1.3) opens this app directly. A **Status › Open from Ghostty**
  row sets the app as the default `.ghostty` editor in one click.
- Status offers a safe, confirmed rename of a pre-1.3 `config` to `config.ghostty` — same file and
  contents, just the name Ghostty now prefers (and the one its ⌘, editor lookup keys on).
- `config.ghostty` is preferred over the legacy extension-less `config` when both exist, matching
  Ghostty ≥ 1.3 (which reads only the `.ghostty` file in that case); a first-ever write creates
  `config.ghostty` rather than `config`.
- Opening a `.ghostty` file with the app (Finder or Ghostty's ⌘,) focuses the editor and re-syncs
  from disk; opening a file that is *not* the active config shows an honest mismatch alert instead
  of silently displaying a different file.
- A packaged, double-clickable `.app` via `scripts/package-app.sh`.

Built and verified against **Ghostty 1.3.1**.
