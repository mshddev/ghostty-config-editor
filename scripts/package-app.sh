#!/usr/bin/env bash
#
# Package the SwiftPM executable into a double-clickable macOS .app bundle.
#
# Produces dist/GhosttyConfigEditor.app — a self-contained, ad-hoc-signed app
# you can drop in /Applications and launch from Spotlight or the Dock. No
# terminal or Xcode needed to use it day-to-day.
#
# Usage:
#   scripts/package-app.sh            # build + package into dist/
#   scripts/package-app.sh --install  # also copy the result to /Applications
#
# The app is intentionally NOT sandboxed: it execs your local `ghostty` binary
# and reads ~/.config/ghostty, neither of which a sandboxed app could reach.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME="GhosttyConfigEditor"
DISPLAY_NAME="Ghostty Config Editor"
BUNDLE_ID="com.mshddev.GhosttyConfigEditor"
SHORT_VERSION="0.1.0"
BUILD_VERSION="1"
MIN_MACOS="14.0"
COPYRIGHT="Copyright © 2026 mshddev. Released under the MIT License. Not affiliated with the Ghostty project."

# The Bundle.module resource bundle SwiftPM emits for the kit target. It lives in
# Contents/Resources, the first location Bundle.module probes (Bundle.main.resourceURL).
RESOURCE_BUNDLE="${APP_NAME}_GhosttyConfigKit.bundle"

RELEASE_DIR="${ROOT}/.build/release"
DIST_DIR="${ROOT}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

echo "==> Building release binary"
swift build -c release

BINARY="${RELEASE_DIR}/${APP_NAME}"
[ -x "${BINARY}" ] || { echo "error: release binary not found at ${BINARY}" >&2; exit 1; }

echo "==> Assembling ${APP_NAME}.app"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

cp "${BINARY}" "${MACOS_DIR}/${APP_NAME}"

# Resource bundle goes in Contents/Resources so it seals as plain data (it is a
# flat .bundle with no Info.plist; codesign --deep would reject it as nested code).
if [ -d "${RELEASE_DIR}/${RESOURCE_BUNDLE}" ]; then
  cp -R "${RELEASE_DIR}/${RESOURCE_BUNDLE}" "${RES_DIR}/${RESOURCE_BUNDLE}"
else
  echo "warning: resource bundle ${RESOURCE_BUNDLE} not found — intent search data may be missing" >&2
fi

# Optional app icon: drop an AppIcon.icns at packaging/AppIcon.icns to embed it.
ICON_KEY=""
if [ -f "${ROOT}/packaging/AppIcon.icns" ]; then
  cp "${ROOT}/packaging/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
  ICON_KEY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
fi

echo "==> Writing Info.plist"
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${SHORT_VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>${COPYRIGHT}</string>
${ICON_KEY}
</dict>
</plist>
PLIST

echo "==> Writing PkgInfo"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "==> Ad-hoc code signing"
# Ad-hoc signature so Gatekeeper lets the local user launch it without a
# developer certificate. No --deep: the only nested .bundle is flat resource
# data, sealed into the app's CodeResources rather than signed as code.
codesign --force --sign - "${APP_DIR}"
codesign --verify --strict "${APP_DIR}" && echo "    signature verified"

echo "==> Done: ${APP_DIR}"

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "${APP_DIR}" "/Applications/${APP_NAME}.app"
  echo "    installed: /Applications/${APP_NAME}.app"
fi
