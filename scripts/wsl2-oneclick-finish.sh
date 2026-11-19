#!/usr/bin/env bash
set -euo pipefail

# StylusClear v0.7.0 Minimal Irreducible Local Finisher (WSL2 Ubuntu 22.04/24.04)
# Broadcasts pre-verified artifacts/clearing_stylus.wasm + Solidity contracts to
# Arbitrum Sepolia (421614) and Robinhood Chain Testnet (46630), then builds demo-final.mp4.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENTITY_DIR="${STYLUSCLEAR_ENTITY_DIR:-$ROOT_DIR/../代码任务所需实体}"
CACHE_DIR="$HOME/.cache/stylusclear_entity_sandbox"

if ! command -v forge >/dev/null 2>&1 && [[ -f "$ENTITY_DIR/bootstrap_sandbox.py" ]]; then
  echo "[wsl2-finish] Bootstrapping offline toolchain from $ENTITY_DIR..."
  python3 "$ENTITY_DIR/bootstrap_sandbox.py" --src "$ENTITY_DIR" --dst "$CACHE_DIR" --modules 01,02,03,06,07
fi

if [[ -f "$CACHE_DIR/activate_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$CACHE_DIR/activate_env.sh"
fi

# Clean trailing colon in NODE_PATH if unset previously (D-06)
export NODE_PATH="${NODE_PATH%:}"

# PEP 668 safe brotli check on Ubuntu 24.04 cp312 (D-06)
if ! python3 -c "import brotli" >/dev/null 2>&1; then
  if ! command -v brotli >/dev/null 2>&1; then
    python3 -m pip install --user --break-system-packages brotli >/dev/null 2>&1 || true
  fi
fi

bash scripts/verify-judge-60s.sh

if [[ -n "${PRIVATE_KEY:-}" ]]; then
  bash scripts/deploy-sepolia.sh
  bash scripts/demo-sepolia-live.sh sepolia
  if [[ "${SKIP_ROBINHOOD:-0}" != "1" ]]; then
    bash scripts/deploy-robinhood-testnet.sh
    bash scripts/demo-sepolia-live.sh robinhood
  fi
fi

if [[ -f "docs/assets/video_kit/master_audio.wav" ]]; then
  bash scripts/build-final-video.sh "${LIVE_CLIP_PATH:-}" "$ROOT_DIR/docs/assets/demo-final.mp4"
fi

echo "[wsl2-finish] Complete."
