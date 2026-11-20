#!/usr/bin/env sh
# Prepares a new bb worktree: downloads the crates, since AGENTS.md builds with --offline.
# A failed download is reported and skipped, so the worktree still opens.
set -u

if ! command -v cargo >/dev/null 2>&1; then
  printf '[bb-env-setup] Warning: cargo not found; skipping crate download\n'
  exit 0
fi

printf '[bb-env-setup] Running: cargo fetch\n'
if cargo fetch --locked; then
  printf '[bb-env-setup] Completed: cargo fetch\n'
else
  printf '[bb-env-setup] Warning: cargo fetch failed (exit %s); continuing\n' "$?"
fi
