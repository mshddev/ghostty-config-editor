---
title: "Packaging a SwiftPM SwiftUI Executable into a Signable macOS .app"
date: 2026-06-16
category: docs/solutions/tooling-decisions/
module: GhosttyConfigEditor
problem_type: tooling_decision
component: tooling
severity: high
symptoms:
  - "codesign: bundle format unrecognized, invalid, or unsuitable (on the SwiftPM resource .bundle)"
  - "swift run launches the process but no window appears and there is no Dock icon"
  - "Bundle.module fatalErrors at launch when the resource bundle is misplaced in the .app"
root_cause: incomplete_setup
resolution_type: tooling_addition
applies_when:
  - "Packaging a SwiftPM executable (SwiftUI/AppKit GUI) into a distributable .app"
  - "Code signing (ad-hoc or Developer ID) an app whose SwiftPM targets declare resources"
  - "A bare SwiftPM SwiftUI executable runs but never shows a window"
related_components:
  - development_workflow
  - documentation
tags:
  - swiftpm
  - macos
  - codesign
  - app-bundle
  - bundle-module
  - swiftui
  - packaging
  - activation-policy
---

# Packaging a SwiftPM SwiftUI Executable into a Signable macOS .app

## Context

`GhosttyConfigEditor` is a native macOS SwiftUI app built as a **Swift Package**, not an `.xcodeproj`: a library target `GhosttyConfigKit` holds all logic and ships `intent-map.json` via `resources: [.process("Resources")]`, and a thin executable target `GhosttyConfigEditor` is the SwiftUI shell (swift-tools 6.0, macOS 14 floor).

Turning that executable into a distributable, double-clickable `.app` — launchable from Spotlight/Dock without `swift run` or Xcode — hits three connected, non-obvious walls that must be solved together:

1. The app shows **no window** when run as a bare SwiftPM executable.
2. **`codesign --deep` rejects** SwiftPM's flat resource bundle.
3. **`Bundle.module` must still resolve** `intent-map.json` from inside the assembled `.app`.

None of the three produces an obvious error pointing at the real cause, which is what makes them worth recording.

## Guidance

The end-to-end recipe that works, captured durably as `scripts/package-app.sh`.

**1. Promote the bare executable to a foreground app.** A SwiftUI `App` launched without an `.app` bundle starts as a background agent (no window, no Dock). Add an app delegate that bumps the activation policy — a harmless no-op once inside a real bundle:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct GhosttyConfigEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { /* WindowGroup { … } */ }
}
```

**2. Assemble the bundle with the resource bundle in `Resources/`, never `MacOS/`:**

```
GhosttyConfigEditor.app/
  Contents/
    Info.plist
    PkgInfo
    MacOS/
      GhosttyConfigEditor                              # the executable binary
    Resources/
      GhosttyConfigEditor_GhosttyConfigKit.bundle      # flat SwiftPM resource bundle
```

**3. Sign and verify WITHOUT `--deep`,** so the flat resource bundle is sealed as ordinary resource data into `_CodeSignature/CodeResources` instead of being treated as nested code:

```bash
codesign --force --sign - GhosttyConfigEditor.app
codesign --verify --strict GhosttyConfigEditor.app
```

**4. Write an `Info.plist` that makes a bare executable behave as a proper app:**

| Key | Value |
| --- | --- |
| `CFBundleExecutable` | `GhosttyConfigEditor` |
| `CFBundleIdentifier` | app identifier |
| `CFBundlePackageType` | `APPL` |
| `LSMinimumSystemVersion` | `14.0` |
| `NSPrincipalClass` | `NSApplication` |
| `NSHighResolutionCapable` | `true` |
| `CFBundleShortVersionString` / `CFBundleVersion` | version strings |

The script chains these: `swift build -c release` → assemble (binary in `MacOS/`, resource bundle in `Resources/`, `Info.plist`, `PkgInfo`) → `codesign --force --sign -` → `codesign --verify --strict` → optional `--install` copies to `/Applications`. The app is intentionally **not sandboxed** — it execs the local `ghostty` binary and reads `~/.config/ghostty`, neither reachable from a sandbox.

## Why This Matters

- **Activation policy.** A SwiftUI `App` launched as a bare executable defaults to `.prohibited` activation policy — macOS treats it as a background agent, so no window and no Dock presence. `setActivationPolicy(.regular)` + `activate(ignoringOtherApps:)` promotes it. Without this, the app silently appears to "do nothing."
- **Why `--deep` fails.** SwiftPM emits an executable target's resource bundle as a **flat** bundle — a directory holding the resource files directly (here just `intent-map.json`), with **no `Info.plist` and no `Contents/`** structure. `codesign --deep` recurses into anything ending in `.bundle` and tries to sign it as nested **code**; a bundle without an `Info.plist` is not a valid code bundle, yielding `bundle format unrecognized, invalid, or unsuitable`. Dropping `--deep` makes `codesign` seal the bundle's bytes as resource data, which is exactly what a resource-only bundle needs.
- **Why `Resources/` is the correct location.** For a SwiftPM executable target, the generated `Bundle.module` accessor probes candidate URLs in order, the **first** being `Bundle.main.resourceURL` — which for an `.app` is `Contents/Resources`. Placing the bundle there makes the in-app lookup path match the `swift run` path (where it sits beside the binary in `.build/release`), so resource loading succeeds instead of `fatalError`-ing at launch. The same placement satisfies both signing and resource resolution.

The cost of getting any of these wrong is a silent failure (no window; launch crash) or a hard stop at the signing step — each easy to misattribute to the wrong layer.

## When to Apply

- Packaging any SwiftPM executable (SwiftUI or AppKit GUI) into a distributable `.app`.
- Code signing — ad-hoc (`-`) or Developer ID — an app built from SwiftPM targets that declare `resources:`.
- Diagnosing a bare SwiftPM SwiftUI executable that runs but never shows a window.

## Examples

**Before — the `--deep` attempt that fails.** Resource bundle placed next to the binary in `Contents/MacOS/` (mirroring `.build/release`), signed deeply:

```bash
# WRONG: bundle in MacOS/, signing with --deep
cp -R .build/release/GhosttyConfigEditor_GhosttyConfigKit.bundle GhosttyConfigEditor.app/Contents/MacOS/
codesign --force --deep --sign - GhosttyConfigEditor.app
# => GhosttyConfigEditor.app: bundle format unrecognized, invalid, or unsuitable
#    In subcomponent: .../Contents/MacOS/GhosttyConfigEditor_GhosttyConfigKit.bundle
```

**After — bundle in `Resources/`, signed shallow:**

```bash
# RIGHT: bundle in Resources/, no --deep
cp -R .build/release/GhosttyConfigEditor_GhosttyConfigKit.bundle GhosttyConfigEditor.app/Contents/Resources/
codesign --force --sign - GhosttyConfigEditor.app
codesign --verify --strict GhosttyConfigEditor.app          # signature verified
```

**Automation pitfall — window-server owner name vs process name.** When scripting screenshots or UI automation against the packaged app, the app is identified two different ways:

- `CGWindowListCopyWindowInfo`'s `kCGWindowOwnerName` is the **`CFBundleDisplayName`** (e.g. `"Ghostty Config Editor"`, with spaces).
- AppleScript System Events `application process "<name>"` uses the **executable name** (`"GhosttyConfigEditor"`, no spaces).

Filtering by the wrong one silently returns nothing. For robust per-window capture, match `owner == display name` to get the `CGWindowID`, then:

```bash
screencapture -o -l<windowID> out.png
```

This survives multi-display setups and Retina point↔pixel scaling, unlike `screencapture -R x,y,w,h`, which errored `could not create image from rect` on a dual-display 5K setup.

## Related

- `scripts/package-app.sh` — the durable build → assemble → sign → verify → install artifact.
- `packaging/make-icon.swift` — headless AppKit icon generator; `package-app.sh` auto-embeds `packaging/AppIcon.icns` and sets `CFBundleIconFile` when present.
- Project structure rationale (SwiftPM over `.xcodeproj`) is recorded in the project's auto-memory.
