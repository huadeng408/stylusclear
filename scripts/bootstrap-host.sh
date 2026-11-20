#!/usr/bin/env bash
set -euo pipefail
echo "[bootstrap-host] Verifying required local tools for StylusClear v1.2.0..."
missing=0
for cmd in git rustc cargo forge cast anvil solc wasm-opt brotli python3 node ffmpeg; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  [OK] $cmd -> $(command -v "$cmd")"
  else
    echo "  [MISSING] $cmd"
    missing=1
  fi
done
if command -v cargo-stylus >/dev/null 2>&1; then
  echo "  [OK] cargo-stylus"
else
  echo "  [NOTE] cargo-stylus not found (install via: cargo install cargo-stylus)"
fi
exit "$missing"
