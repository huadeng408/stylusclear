#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export PATH="$HOME/.foundry/bin:$HOME/.cargo/bin:/usr/local/bin:$PATH"
OFFLINE_TOOLCHAIN_DIR="${STYLUSCLEAR_ENTITY_DIR:-}"
RUN_FULL_VERIFY="${RUN_FULL_VERIFY:-0}"
SKIP_DEPLOY=0
LIVE_CLIP=""

for arg in "$@"; do
  case "$arg" in
    --verify|-verify) RUN_FULL_VERIFY=1 ;;
    --skip-deploy) SKIP_DEPLOY=1 ;;
    *)
      if [[ -z "$LIVE_CLIP" && -f "$arg" ]]; then
        LIVE_CLIP="$arg"
      fi
      ;;
  esac
done

echo "[wsl2-finish] Repo root: $ROOT_DIR"
if [[ -n "$OFFLINE_TOOLCHAIN_DIR" && -d "$OFFLINE_TOOLCHAIN_DIR" ]]; then
  echo "[wsl2-finish] Offline toolchain dir: $OFFLINE_TOOLCHAIN_DIR"
fi

if [[ "$RUN_FULL_VERIFY" == "1" ]]; then
  echo "[wsl2-finish] Running full 5-stage judge verification..."
  bash scripts/verify-judge-60s.sh
fi

if [[ "$SKIP_DEPLOY" == "0" ]]; then
  if [[ -z "${PRIVATE_KEY:-}" ]]; then
    echo "ERROR: PRIVATE_KEY is not set. Run via 2-DEPLOY-AND-PUSH.cmd (masked SecureString prompt) or pass --skip-deploy." >&2
    exit 1
  fi
  if ! command -v cast >/dev/null 2>&1; then
    echo "ERROR: Foundry 'cast' is required on PATH inside WSL2 (install Foundry via foundryup)." >&2
    exit 1
  fi
  echo "[wsl2-finish] Deploying to Arbitrum Sepolia (421614) via cloud-precompiled artifacts..."
  REQUIRE_STYLUS="${REQUIRE_STYLUS:-1}" USE_ATOMIC_FACTORY="${USE_ATOMIC_FACTORY:-1}" bash scripts/deploy-sepolia.sh
  bash scripts/demo-sepolia-live.sh sepolia
  if [[ "${SKIP_ROBINHOOD:-0}" != "1" ]]; then
    echo "[wsl2-finish] Deploying to Robinhood Chain Testnet (46630) via cloud-precompiled artifacts..."
    REQUIRE_STYLUS="${REQUIRE_STYLUS:-1}" USE_ATOMIC_FACTORY="${USE_ATOMIC_FACTORY:-1}" bash scripts/deploy-robinhood-testnet.sh
    bash scripts/demo-sepolia-live.sh robinhood
  fi
fi

if [[ -n "$LIVE_CLIP" ]]; then
  if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    echo "ERROR: ffmpeg and ffprobe are required on PATH to assemble the final 1080p60 demo video." >&2
    exit 1
  fi
  echo "[wsl2-finish] Assembling final 1080p60 video with live clip: $LIVE_CLIP"
  bash scripts/build-final-video.sh "$LIVE_CLIP"
else
  echo "[wsl2-finish] No live recording clip supplied; skipping final MP4 assembly."
  echo "[wsl2-finish] NOTE: Never submit an older pre-v1.2.0 MP4 with v1.2.0 metrics. Re-record live clip and run: bash scripts/build-final-video.sh <clip.mp4>"
fi

echo "[wsl2-finish] Complete. Review 'git status' then run: git add deployments web/deployments docs/benchmarks web/benchmarks.generated.mjs docs/assets && git commit -m 'chore: record live testnet deployments and benchmarks' && git push origin main"
