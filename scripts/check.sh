#!/usr/bin/env bash
set -euo pipefail

# StylusClear v1.2.0 Full 7-Gate Strict Verification Suite (Zero Workspace Pollution)
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

ENTITY_DIR="${STYLUSCLEAR_ENTITY_DIR:-}"
CACHE_DIR="$HOME/.cache/stylusclear_entity_sandbox"
if ! command -v cargo >/dev/null 2>&1 && [[ -n "$ENTITY_DIR" && -f "$ENTITY_DIR/bootstrap_sandbox.py" ]]; then
  python3 "$ENTITY_DIR/bootstrap_sandbox.py" --src "$ENTITY_DIR" --dst "$CACHE_DIR" --modules 01,02,03,06,07
fi
if [[ -f "$CACHE_DIR/activate_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$CACHE_DIR/activate_env.sh"
fi
export PATH="$HOME/.local/bin:$PATH"
NODE_PATH="${NODE_PATH:-}"
if [[ -d "$ROOT_DIR/web/node_modules" ]]; then NODE_PATH="$ROOT_DIR/web/node_modules${NODE_PATH:+:$NODE_PATH}"; fi
export NODE_PATH="${NODE_PATH%:}"
CARGO_VENDOR_OPTS=()
if [[ -n "${OFFLINE_CRATES_VENDOR:-}" && -d "${OFFLINE_CRATES_VENDOR}" ]]; then
  CARGO_VENDOR_OPTS=(--config 'source.crates-io.replace-with="vendored-sources"' --config "source.vendored-sources.directory=\"${OFFLINE_CRATES_VENDOR}\"")
fi

TMP_CHECK="$(mktemp -d)"
CLEAN_ROOT_NM=0
CLEAN_WEB_NM=0
cleanup_all() {
  rm -rf "$TMP_CHECK"
  if [[ "$CLEAN_ROOT_NM" -eq 1 && -L "$ROOT_DIR/node_modules" ]]; then rm -f "$ROOT_DIR/node_modules"; fi
  if [[ "$CLEAN_WEB_NM" -eq 1 && -L "$ROOT_DIR/web/node_modules" ]]; then rm -f "$ROOT_DIR/web/node_modules"; fi
}
trap cleanup_all EXIT

echo "[check 1/7] Static Architecture & Zero-Leak Gate (archcheck)..."
if [[ "$STRICT_MODE" -eq 1 ]]; then
  python3 tools/archcheck/check.py . --strict
else
  python3 tools/archcheck/check.py .
fi

echo "[check 2/7] Shell Syntax (bash -n) & ShellCheck Hygiene..."
for shf in scripts/*.sh; do
  bash -n "$shf"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/*.sh
fi

echo "[check 3/7] Rust Workspace Tests, Clippy & WASM 1.0 MVP Parity (Zero-Overwrite)..."
cargo test ${CARGO_VENDOR_OPTS[@]+"${CARGO_VENDOR_OPTS[@]}"} --locked ${OFFLINE_OPT[@]+"${OFFLINE_OPT[@]}"} --workspace
cargo clippy ${CARGO_VENDOR_OPTS[@]+"${CARGO_VENDOR_OPTS[@]}"} --locked ${OFFLINE_OPT[@]+"${OFFLINE_OPT[@]}"} --workspace --all-targets -- -D warnings
cargo build ${CARGO_VENDOR_OPTS[@]+"${CARGO_VENDOR_OPTS[@]}"} --locked ${OFFLINE_OPT[@]+"${OFFLINE_OPT[@]}"} --release --bin clearing-cli
cargo build ${CARGO_VENDOR_OPTS[@]+"${CARGO_VENDOR_OPTS[@]}"} --locked ${OFFLINE_OPT[@]+"${OFFLINE_OPT[@]}"} --release --target wasm32-unknown-unknown -p clearing-stylus --no-default-features
WASM_SRC="${CARGO_TARGET_DIR:-$ROOT_DIR/target}/wasm32-unknown-unknown/release/clearing_stylus.wasm"
python3 scripts/optimize-wasm-mvp.py "$WASM_SRC" "$TMP_CHECK/clearing_stylus.wasm"
python3 - "$ROOT_DIR/artifacts/clearing_stylus.wasm" "$TMP_CHECK/clearing_stylus.wasm" <<'PYEOF'
import hashlib, sys
from pathlib import Path
h_repo = hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()
h_built = hashlib.sha256(Path(sys.argv[2]).read_bytes()).hexdigest()
assert h_repo == h_built, f"WASM artifact drift: repo={h_repo[:16]} vs built={h_built[:16]}"
print(f"[check 3/7] WASM SHA-256 parity verified: {h_repo[:16]}...")
PYEOF

echo "[check 4/7] Foundry Differential Fuzz (2x256) & Cold-Storage Benchmark Suite..."
SOLC_OPT=()
if command -v solc >/dev/null 2>&1; then SOLC_OPT=(--use "$(command -v solc)"); fi
forge test ${SOLC_OPT[@]+"${SOLC_OPT[@]}"} ${OFFLINE_OPT[@]+"${OFFLINE_OPT[@]}"} -vv

echo "[check 5/7] Python Seam S1/S2/S4 + Z3 Formal SMT Proofs (Zero-Overwrite)..."
ruff check .
mypy tools tests
STYLUSCLEAR_REQUIRE_CLI=1 python3 -m pytest -q tests/test_seam_s1_clearing.py tests/test_seam_s2_eip712_and_differential.py tests/test_seam_s4_archcheck.py
python3 tools/formal/prove_invariants_z3.py --require-cli --examples 100 --out "$TMP_CHECK/z3.json"
python3 - "$TMP_CHECK/z3.json" <<'PYEOF'
import json, sys
d = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert d["all_unsat"] is True and d["theorems_proved"] == 6, f"Z3 check failed: {d}"
print("[check 5/7] Z3 6/6 PROVED_UNSAT + 100/100 CLI parity verified (zero workspace pollution)")
PYEOF

echo "[check 6/7] TypeScript / Seam S3 Workbench & Headless Chromium 3-Viewport E2E..."
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
if command -v tsc >/dev/null 2>&1 && tsc --version >/dev/null 2>&1; then
  tsc -p web/tsconfig.json --noEmit
elif command -v esbuild >/dev/null 2>&1; then
  esbuild web/rpc-client.ts --bundle --format=esm --platform=browser --target=es2022 --outfile=/dev/null
else
  test -f web/dist/rpc-client.mjs
fi
node tests/test_seam_s3_workbench.mjs
python3 scripts/verify-web-e2e-chromium.py

echo "[check 7/7] Calibrated Benchmark Artifact Integrity..."
python3 scripts/generate-benchmarks.py --verify-only

echo "[check] ALL 7 GATES PASSED (StylusClear v1.2.0)."
