#!/usr/bin/env bash
set -euo pipefail
# pgrep/pkill fail under some locales (C.UTF-8), which left the old app running.
export LC_ALL=C

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Scrawl Remote, this fork, installs beside the official Scrawl.app (dev.kitlangton.scrawl):
# its own name and bundle id (src/identity.rs), no Sparkle (the official appcast would replace
# it), and a self-signed certificate (scripts/signing-identity.sh) so macOS keeps its
# permissions across rebuilds. Nothing here touches the official app.
APP_NAME="Scrawl Remote"
BUNDLE_ID="com.scowalt.scrawl-remote"
# SCRAWL_APP_DIR builds the signed bundle somewhere else; SCRAWL_NO_LAUNCH=1 skips the restart.
APP_DIR="${SCRAWL_APP_DIR:-${HOME}/Applications/${APP_NAME}.app}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
SIGN_NAME="Scrawl Remote Local Signing"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "${REPO_DIR}/Cargo.toml" | head -1)"

cd "${REPO_DIR}"
KEYCHAIN="$(SCRAWL_SIGN_NAME="${SIGN_NAME}" "${REPO_DIR}/scripts/signing-identity.sh")"
taskpolicy -c utility cargo build -j 3

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
rm -rf "${FRAMEWORKS_DIR}"

rm -f "${MACOS_DIR}/scrawl" "${MACOS_DIR}/scrawl-helper"
cp -f "${REPO_DIR}/target/debug/scrawl" "${MACOS_DIR}/scrawl"
cp -f "${REPO_DIR}/target/debug/scrawl-helper" "${MACOS_DIR}/scrawl-helper"
chmod +x "${MACOS_DIR}/scrawl" "${MACOS_DIR}/scrawl-helper"

if [[ -f "${REPO_DIR}/assets/Scrawl.icns" ]]; then
  cp -f "${REPO_DIR}/assets/Scrawl.icns" "${RESOURCES_DIR}/Scrawl.icns"
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
  <string>1</string>
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
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>${BUNDLE_ID}</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>scrawl</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

SIGN=(codesign --force --keychain "${KEYCHAIN}" --sign "${SIGN_NAME}")
# The helper keeps the id in its embedded Info.plist (Apple's speech assets are reserved by it).
"${SIGN[@]}" --identifier "dev.kitlangton.scrawl.helper" "${MACOS_DIR}/scrawl-helper"
"${SIGN[@]}" --identifier "${BUNDLE_ID}" "${APP_DIR}"
codesign --verify --strict "${APP_DIR}"

if [[ "${SCRAWL_NO_LAUNCH:-0}" == "1" ]]; then
  exit 0
fi

# Only this app's processes: the official app runs from Scrawl.app, which this doesn't match.
PATTERN="${APP_NAME}.app/Contents/MacOS/scrawl"
scrawl_running() {
  local status=0
  pgrep -f "${PATTERN}" >/dev/null || status=$?
  case "${status}" in
    0) return 0 ;;
    1) return 1 ;;
    *) echo "pgrep failed (exit ${status}); can't tell whether the old ${APP_NAME} stopped" >&2; exit 1 ;;
  esac
}

pkill -f "${PATTERN}" 2>/dev/null || true
for _ in {1..40}; do
  scrawl_running || break
  sleep 0.05
done
if scrawl_running; then
  pgrep -fl "${PATTERN}" >&2 || true
  echo "the old ${APP_NAME} is still running; quit it and run this again" >&2
  exit 1
fi
open "${APP_DIR}"
sleep 0.5
pgrep -fl "${PATTERN}"
