# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — Initial release

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
- A packaged, double-clickable `.app` via `scripts/package-app.sh`.

Built and verified against **Ghostty 1.3.1**.
