#!/usr/bin/env bash
set -euo pipefail

# StylusClear v1.1.0 Fast Judge Verification (< 30 seconds)
START_TS="$(date +%s)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f "$HOME/.cache/stylusclear_entity_sandbox/activate_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cache/stylusclear_entity_sandbox/activate_env.sh"
fi
CARGO_VENDOR_OPTS=()
OFFLINE_ARG=()
if [[ -n "${OFFLINE_CRATES_VENDOR:-}" && -d "${OFFLINE_CRATES_VENDOR}" ]]; then
  CARGO_VENDOR_OPTS=(--config 'source.crates-io.replace-with="vendored-sources"' --config "source.vendored-sources.directory=\"${OFFLINE_CRATES_VENDOR}\"")
  OFFLINE_ARG=(--offline)
fi

echo "=== [1/5] Architecture, ABI Parity & WASM 1.0 MVP (< 24 KiB Brotli) ==="
python3 tools/archcheck/check.py . --strict
wasm-opt --mvp-features -O0 artifacts/clearing_stylus.wasm -o /dev/null
python3 scripts/generate-benchmarks.py --verify-only

echo "=== [2/5] Rust Clippy (-D warnings), Core/Stylus Tests & CLI Build ==="
cargo clippy "${CARGO_VENDOR_OPTS[@]}" --locked "${OFFLINE_ARG[@]}" --workspace --all-targets -- -D warnings
cargo test "${CARGO_VENDOR_OPTS[@]}" --locked "${OFFLINE_ARG[@]}" --workspace --quiet
cargo build "${CARGO_VENDOR_OPTS[@]}" --locked "${OFFLINE_ARG[@]}" --release --bin clearing-cli --quiet

echo "=== [3/5] Foundry Differential & Cold-Storage Gas Suite ==="
SOLC_OPT=(); if command -v solc >/dev/null 2>&1; then SOLC_OPT=(--use "$(command -v solc)"); fi
forge test "${SOLC_OPT[@]}" "${OFFLINE_ARG[@]}"

echo "=== [4/5] Z3 Formal SMT Proofs (6 Theorems + 100/100 CLI Fuzz) & Seam S1/S2/S4 ==="
TMP_Z3_OUT="$(mktemp)"
trap 'rm -f "$TMP_Z3_OUT"' EXIT
python3 tools/formal/prove_invariants_z3.py --require-cli --out "$TMP_Z3_OUT"
STYLUSCLEAR_REQUIRE_CLI=1 python3 -m pytest -q

echo "=== [5/5] Dual-Chain Web Workbench Seam S3 (Zero node_modules) ==="
node tests/test_seam_s3_workbench.mjs

ELAPSED="$(( $(date +%s) - START_TS ))"
echo "=== JUDGE VERIFICATION SUCCEEDED IN ${ELAPSED}s ==="
