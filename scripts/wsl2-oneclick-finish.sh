#!/usr/bin/env bash
set -euo pipefail

# StylusClear v1.1.0 Minimal Irreducible Local Finisher (WSL2 Ubuntu 22.04/24.04)
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

# Safe NODE_PATH handling under set -u (prevents unbound variable crash)
NODE_PATH="${NODE_PATH:-}"
if [[ -d "$ROOT_DIR/web/node_modules" ]]; then
  NODE_PATH="${ROOT_DIR}/web/node_modules${NODE_PATH:+:$NODE_PATH}"
fi
export NODE_PATH="${NODE_PATH%:}"

# PEP 668 safe brotli check on Ubuntu 24.04 cp312
if ! python3 -c "import brotli" >/dev/null 2>&1; then
  if ! command -v brotli >/dev/null 2>&1; then
    python3 -m pip install --user --break-system-packages brotli >/dev/null 2>&1 || true
  fi
fi

if [[ "${RUN_FULL_VERIFY:-0}" == "1" || "${1:-}" == "--verify" ]]; then
  bash scripts/verify-judge-60s.sh
else
  echo "[oneclick] Fast broadcast mode (all 7 CI gates pre-verified in cloud; pass --verify to re-run locally)"
fi

if [[ -n "${PRIVATE_KEY:-}" ]]; then
  bash scripts/deploy-sepolia.sh
  bash scripts/demo-sepolia-live.sh sepolia
  if [[ "${SKIP_ROBINHOOD:-0}" != "1" ]]; then
    bash scripts/deploy-robinhood-testnet.sh
    bash scripts/demo-sepolia-live.sh robinhood
  fi
fi

VIDEO_KIT_DIR="${STYLUSCLEAR_VIDEO_KIT_DIR:-$ROOT_DIR/docs/assets/video_kit}"
if [[ ! -f "$VIDEO_KIT_DIR/master_audio.m4a" && ! -f "$VIDEO_KIT_DIR/master_audio.wav" ]]; then
  SIBLING_KIT="$ROOT_DIR/../project5-stylus-clearing-engine/docs/assets/video_kit"
  if [[ -d "$SIBLING_KIT" ]]; then
    VIDEO_KIT_DIR="$SIBLING_KIT"
    export STYLUSCLEAR_VIDEO_KIT_DIR="$VIDEO_KIT_DIR"
  fi
fi

if [[ -f "$VIDEO_KIT_DIR/master_audio.m4a" || -f "$VIDEO_KIT_DIR/master_audio.wav" ]]; then
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "[ERROR] ffmpeg not found in PATH. Install ffmpeg or mount 视频制作所需实体/05_ffmpeg_latest_gpl." >&2
    exit 1
  fi
  if [[ -n "${LIVE_CLIP_PATH:-}" && -f "${LIVE_CLIP_PATH}" ]]; then
  bash scripts/build-final-video.sh "$LIVE_CLIP_PATH" "$ROOT_DIR/docs/assets/demo-final.mp4"
else
  echo "[oneclick] Reusing cloud-rendered 1080p60 demo-preview.mp4 (set LIVE_CLIP_PATH to splice a 32s live clip)"
fi
else
  echo "[wsl2-finish] INFO: video_kit audio not found in $VIDEO_KIT_DIR; copy docs/assets/video_kit from Drive or set STYLUSCLEAR_VIDEO_KIT_DIR to build demo-final.mp4."
fi

echo "[wsl2-finish] Complete."
