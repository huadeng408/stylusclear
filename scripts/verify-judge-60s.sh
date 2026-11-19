#!/usr/bin/env bash
set -euo pipefail

# StylusClear v0.7.0 Fast Judge Verification (< 20 seconds)
START_TS="$(date +%s)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f "$HOME/.cache/stylusclear_entity_sandbox/activate_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cache/stylusclear_entity_sandbox/activate_env.sh"
fi
export NODE_PATH="${NODE_PATH%:}"
CARGO_VENDOR_OPTS=()
if [[ -n "${OFFLINE_CRATES_VENDOR:-}" && -d "${OFFLINE_CRATES_VENDOR}" ]]; then
  CARGO_VENDOR_OPTS=(--config 'source.crates-io.replace-with="vendored-sources"' --config "source.vendored-sources.directory=\"${OFFLINE_CRATES_VENDOR}\"")
fi

echo "=== [1/5] Architecture, ABI Parity & WASM 1.0 MVP (< 24 KB Brotli) ==="
python3 tools/archcheck/check.py . --strict
wasm-opt --mvp-features -O0 artifacts/clearing_stylus.wasm -o /dev/null
python3 scripts/generate-benchmarks.py --verify-only

echo "=== [2/5] Rust Core & Stylus Unit Tests ==="
cargo test "${CARGO_VENDOR_OPTS[@]}" --locked --offline --workspace --quiet

echo "=== [3/5] Foundry Differential & Cold-Storage Gas Suite ==="
SOLC_OPT=(); if command -v solc >/dev/null 2>&1; then SOLC_OPT=(--use "$(command -v solc)"); fi
forge test "${SOLC_OPT[@]}" --offline

echo "=== [4/5] Z3 Formal SMT Proofs (6 Theorems) & Seam S1/S2/S4 ==="
python3 tools/formal/prove_invariants_z3.py
python3 -m pytest -q

echo "=== [5/5] Dual-Chain Web Workbench Seam S3 (421614 & 46630) ==="
CLEAN_ROOT_NM=0
CLEAN_WEB_NM=0
if [[ -d "$HOME/.cache/stylusclear_entity_sandbox/06_node_ts_cloud_sdks/node_pkgs/node_modules" ]]; then
  if [[ ! -e "$ROOT_DIR/node_modules" ]]; then
    ln -s "$HOME/.cache/stylusclear_entity_sandbox/06_node_ts_cloud_sdks/node_pkgs/node_modules" "$ROOT_DIR/node_modules"
    CLEAN_ROOT_NM=1
  fi
  if [[ ! -e "$ROOT_DIR/web/node_modules" ]]; then
    ln -s "$HOME/.cache/stylusclear_entity_sandbox/06_node_ts_cloud_sdks/node_pkgs/node_modules" "$ROOT_DIR/web/node_modules"
    CLEAN_WEB_NM=1
  fi
fi
cleanup_nm() {
  if [[ "$CLEAN_ROOT_NM" -eq 1 && -L "$ROOT_DIR/node_modules" ]]; then rm -f "$ROOT_DIR/node_modules"; fi
  if [[ "$CLEAN_WEB_NM" -eq 1 && -L "$ROOT_DIR/web/node_modules" ]]; then rm -f "$ROOT_DIR/web/node_modules"; fi
}
trap cleanup_nm EXIT
node tests/test_seam_s3_workbench.mjs

ELAPSED="$(( $(date +%s) - START_TS ))"
echo "=== JUDGE VERIFICATION SUCCEEDED IN ${ELAPSED}s ==="
