#!/usr/bin/env bash
# Assembles and signs "Scrawl Remote.app" from built binaries. Used by install-app.sh (a local
# debug build, no updater) and the release workflow (.github/workflows/release-fork.yml, a release
# build with Sparkle). See docs/fork-release.md.
#
#   scripts/assemble-app.sh <binary dir> <app dir> <keychain>
#
# BUILD_NUMBER (CFBundleVersion, default 0) is what Sparkle compares: releases use the workflow's
# run number, local builds 0. SPARKLE_DIR, when set, embeds Sparkle and the update feed.
set -euo pipefail

BIN_DIR="$1"
APP_DIR="$2"
KEYCHAIN="$3"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="Scrawl Remote"
BUNDLE_ID="com.scowalt.scrawl-remote"
SIGN_NAME="Scrawl Remote Signing"
FEED_URL="https://github.com/scowalt/scrawl/releases/latest/download/appcast.xml"
# The private half signs each release's appcast item (SPARKLE_ED_PRIVATE_KEY in the repo's
# Actions secrets, ~/.config/scrawl-remote/signing/sparkle-ed25519.key on Scott's MacBook).
SPARKLE_PUBLIC_KEY="YwzWGNboWT9fY3HyyciQ4Sl/ezxPejk9CYhjtXuxju8="
BUILD_NUMBER="${BUILD_NUMBER:-0}"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "${REPO_DIR}/Cargo.toml" | head -1)"
if [[ "${BUILD_NUMBER}" != "0" ]]; then
  VERSION="${VERSION}-remote.${BUILD_NUMBER}"
fi

CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
rm -rf "${FRAMEWORKS_DIR}"
rm -f "${MACOS_DIR}/scrawl" "${MACOS_DIR}/scrawl-helper"
cp -f "${BIN_DIR}/scrawl" "${MACOS_DIR}/scrawl"
cp -f "${BIN_DIR}/scrawl-helper" "${MACOS_DIR}/scrawl-helper"
chmod +x "${MACOS_DIR}/scrawl" "${MACOS_DIR}/scrawl-helper"
cp -f "${REPO_DIR}/assets/Scrawl.icns" "${RESOURCES_DIR}/Scrawl.icns"

UPDATES=""
if [[ -n "${SPARKLE_DIR:-}" ]]; then
  mkdir -p "${FRAMEWORKS_DIR}"
  /usr/bin/ditto "${SPARKLE_DIR}/Sparkle.framework" "${FRAMEWORKS_DIR}/Sparkle.framework"
  # Checks hourly and installs on its own (sparkle::install_pending_update waits out a capture).
  UPDATES="  <key>SUFeedURL</key>
  <string>${FEED_URL}</string>
  <key>SUPublicEDKey</key>
  <string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <true/>
  <key>SUAllowsAutomaticUpdates</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>3600</integer>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>"
fi

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>scrawl</string>
  <key>CFBundleIconFile</key>
  <string>Scrawl</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Scrawl captures your screen to build annotated agent bundles.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Scrawl records your voice to align transcripts with keyframes.</string>
  <key>NSCameraUsageDescription</key>
  <string>Scrawl mirrors and records a cabled iPhone's screen.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Scrawl transcribes your narration on this Mac.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Scrawl reads the address of the browser tab you captured, to send a capture of a dev site to its project's session.</string>
${UPDATES}
</dict>
</plist>
PLIST
plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null

SIGN=(codesign --force --keychain "${KEYCHAIN}" --sign "${SIGN_NAME}")
if [[ -d "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B" ]]; then
  SPARKLE_VER="${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B"
  "${SIGN[@]}" "${SPARKLE_VER}/XPCServices/Installer.xpc"
  "${SIGN[@]}" --preserve-metadata=entitlements "${SPARKLE_VER}/XPCServices/Downloader.xpc"
  "${SIGN[@]}" "${SPARKLE_VER}/Autoupdate"
  "${SIGN[@]}" "${SPARKLE_VER}/Updater.app"
  "${SIGN[@]}" "${FRAMEWORKS_DIR}/Sparkle.framework"
fi
# The helper keeps the id in its embedded Info.plist (Apple's speech assets are reserved by it).
"${SIGN[@]}" --identifier "dev.kitlangton.scrawl.helper" "${MACOS_DIR}/scrawl-helper"
"${SIGN[@]}" --identifier "${BUNDLE_ID}" "${APP_DIR}"
codesign --verify --strict --deep "${APP_DIR}"
