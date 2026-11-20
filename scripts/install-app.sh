#!/usr/bin/env bash
set -euo pipefail
# pgrep/pkill fail under some locales (C.UTF-8), which left the old app running.
export LC_ALL=C

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Scrawl Remote, this fork, installs beside the official Scrawl.app (dev.kitlangton.scrawl):
# its own name and bundle id (src/identity.rs) and a self-signed certificate
# (scripts/signing-identity.sh) so macOS keeps its permissions across rebuilds. This installs a
# local debug build; releases come from GitHub with updates (docs/fork-release.md,
# scripts/install-release.sh). Nothing here touches the official app.
APP_NAME="Scrawl Remote"
# SCRAWL_APP_DIR builds the signed bundle somewhere else; SCRAWL_NO_LAUNCH=1 skips the restart.
APP_DIR="${SCRAWL_APP_DIR:-${HOME}/Applications/${APP_NAME}.app}"

cd "${REPO_DIR}"
KEYCHAIN="$("${REPO_DIR}/scripts/signing-identity.sh")"
taskpolicy -c utility cargo build -j 3
# A local build: no updater, build number 0, so the releases' Sparkle never sees it as newer.
BUILD_NUMBER=0 "${REPO_DIR}/scripts/assemble-app.sh" "${REPO_DIR}/target/debug" "${APP_DIR}" "${KEYCHAIN}"

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
