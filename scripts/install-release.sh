#!/usr/bin/env bash
# Installs the latest Scrawl Remote release from GitHub into ~/Applications and starts it. After
# this the app updates itself (Sparkle, docs/fork-release.md). Needs nothing but curl and the
# macOS tools; it never touches the official /Applications/Scrawl.app.
set -euo pipefail
export LC_ALL=C

FEED_URL="https://github.com/scowalt/scrawl/releases/latest/download/appcast.xml"
APP_NAME="Scrawl Remote"
APP_DIR="${HOME}/Applications/${APP_NAME}.app"
# The release certificate (scripts/signing-identity.sh): refuse anything signed otherwise.
REQUIREMENT='identifier "com.scowalt.scrawl-remote" and certificate leaf = H"86a746b94f2a7e5555e2b59def20eb5eee47fe29"'

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

curl --fail --silent --show-error --location "${FEED_URL}" -o "${work}/appcast.xml"
url="$(sed -n 's/.*<enclosure url="\([^"]*\)".*/\1/p' "${work}/appcast.xml" | head -1)"
version="$(sed -n 's/.*<sparkle:shortVersionString>\(.*\)<\/sparkle:shortVersionString>.*/\1/p' "${work}/appcast.xml" | head -1)"
[[ -n "${url}" ]] || { echo "no release in ${FEED_URL}" >&2; exit 1; }
echo "Downloading ${APP_NAME} ${version}"
curl --fail --silent --show-error --location "${url}" -o "${work}/app.zip"
/usr/bin/ditto -x -k "${work}/app.zip" "${work}/unzipped"
new="${work}/unzipped/${APP_NAME}.app"
codesign --verify --strict --deep -R="${REQUIREMENT}" "${new}"

PATTERN="${APP_NAME}.app/Contents/MacOS/scrawl"
pkill -f "${PATTERN}" 2>/dev/null || true
for _ in {1..40}; do
  pgrep -f "${PATTERN}" >/dev/null || break
  sleep 0.05
done
mkdir -p "${HOME}/Applications"
rm -rf "${APP_DIR}"
/usr/bin/ditto "${new}" "${APP_DIR}"
open "${APP_DIR}"
sleep 1
pgrep -fl "${PATTERN}"
echo "Installed ${APP_NAME} ${version}; it updates itself from now on."
