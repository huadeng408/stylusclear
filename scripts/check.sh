#!/usr/bin/env bash
set -euo pipefail

# StylusClear v1.0.0 Full 7-Gate Strict Verification Suite
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

STRICT_MODE=0
OFFLINE_OPT=()
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT_MODE=1 ;;
    --offline) OFFLINE_OPT=(--offline) ;;
  esac
done

ENTITY_DIR="${STYLUSCLEAR_ENTITY_DIR:-$ROOT_DIR/../代码任务所需实体}"
CACHE_DIR="$HOME/.cache/stylusclear_entity_sandbox"
if ! command -v cargo >/dev/null 2>&1 && [[ -f "$ENTITY_DIR/bootstrap_sandbox.py" ]]; then
  python3 "$ENTITY_DIR/bootstrap_sandbox.py" --src "$ENTITY_DIR" --dst "$CACHE_DIR" --modules 01,02,03,06,07
fi
if [[ -f "$CACHE_DIR/activate_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$CACHE_DIR/activate_env.sh"
fi
NODE_PATH="${NODE_PATH:-}"
if [[ -d "$ROOT_DIR/web/node_modules" ]]; then NODE_PATH="$ROOT_DIR/web/node_modules${NODE_PATH:+:$NODE_PATH}"; fi
export NODE_PATH="${NODE_PATH%:}"
CARGO_VENDOR_OPTS=()
if [[ -n "${OFFLINE_CRATES_VENDOR:-}" && -d "${OFFLINE_CRATES_VENDOR}" ]]; then
  CARGO_VENDOR_OPTS=(--config 'source.crates-io.replace-with="vendored-sources"' --config "source.vendored-sources.directory=\"${OFFLINE_CRATES_VENDOR}\"")
fi

echo "[check 1/7] Static Architecture & Zero-Leak Gate (archcheck)..."
if [[ "$STRICT_MODE" -eq 1 ]]; then
  python3 tools/archcheck/check.py . --strict
else
  python3 tools/archcheck/check.py .
fi

echo "[check 2/7] ShellCheck Hygiene..."
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/*.sh
fi

echo "[check 3/7] Rust Workspace Tests, Clippy & WASM 1.0 MVP Verification..."
cargo test "${CARGO_VENDOR_OPTS[@]}" --locked "${OFFLINE_OPT[@]}" --workspace
cargo clippy "${CARGO_VENDOR_OPTS[@]}" --locked "${OFFLINE_OPT[@]}" --workspace --all-targets -- -D warnings
cargo build "${CARGO_VENDOR_OPTS[@]}" --locked "${OFFLINE_OPT[@]}" --release --bin clearing-cli
cargo build "${CARGO_VENDOR_OPTS[@]}" --locked "${OFFLINE_OPT[@]}" --release --target wasm32-unknown-unknown -p clearing-stylus
WASM_SRC="${CARGO_TARGET_DIR:-$ROOT_DIR/target}/wasm32-unknown-unknown/release/clearing_stylus.wasm"
python3 scripts/optimize-wasm-mvp.py "$WASM_SRC" "$ROOT_DIR/artifacts/clearing_stylus.wasm"

echo "[check 4/7] Foundry Differential Fuzz (2x256) & Cold-Storage Benchmark Suite..."
SOLC_OPT=(); if command -v solc >/dev/null 2>&1; then SOLC_OPT=(--use "$(command -v solc)"); fi
forge test "${SOLC_OPT[@]}" "${OFFLINE_OPT[@]}" -vv

echo "[check 5/7] Python Seam S1/S2/S4 + Z3 Formal SMT Proofs..."
python3 -m pytest -q tests/test_seam_s1_clearing.py tests/test_seam_s2_eip712_and_differential.py tests/test_seam_s4_archcheck.py
python3 tools/formal/prove_invariants_z3.py --require-cli --examples 100

echo "[check 6/7] TypeScript Strict Typecheck & Seam S3 Dual-Chain Workbench..."
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
elif [[ -d "$ROOT_DIR/web/node_modules" && ! -e "$ROOT_DIR/node_modules" ]]; then
  ln -s "$ROOT_DIR/web/node_modules" "$ROOT_DIR/node_modules"
  CLEAN_ROOT_NM=1
fi
cleanup_nm() {
  if [[ "$CLEAN_ROOT_NM" -eq 1 && -L "$ROOT_DIR/node_modules" ]]; then rm -f "$ROOT_DIR/node_modules"; fi
  if [[ "$CLEAN_WEB_NM" -eq 1 && -L "$ROOT_DIR/web/node_modules" ]]; then rm -f "$ROOT_DIR/web/node_modules"; fi
}
trap cleanup_nm EXIT
if command -v tsc >/dev/null 2>&1 && tsc --version >/dev/null 2>&1; then
  tsc -p web/tsconfig.json --noEmit
else
  esbuild web/rpc-client.ts --bundle --format=esm --platform=browser --target=es2022 --outfile=/dev/null
fi
node tests/test_seam_s3_workbench.mjs

echo "[check 7/7] Calibrated Benchmark Artifact Integrity..."
python3 scripts/generate-benchmarks.py --verify-only

echo "[check] ALL 7 GATES PASSED (StylusClear v1.0.0)."
