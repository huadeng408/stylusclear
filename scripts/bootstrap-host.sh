#!/usr/bin/env bash
set -euo pipefail
echo "[bootstrap-host] Verifying required local tools for StylusClear v0.8.0..."
missing=0
for cmd in git rustc cargo forge cast anvil solc python3 node ffmpeg; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  [OK] $cmd -> $(command -v "$cmd")"
  else
    echo "  [MISSING] $cmd"
    missing=1
  fi
done
command -v cargo-stylus >/dev/null 2>&1 && echo "  [OK] cargo-stylus" || echo "  [NOTE] cargo-stylus not found (install via: cargo install cargo-stylus)"
exit "$missing"
