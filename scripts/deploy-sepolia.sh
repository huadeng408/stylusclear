#!/usr/bin/env bash
set -euo pipefail

# StylusClear v1.0.0 Atomic Deployment Script (Arbitrum Sepolia — Chain ID 421614)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f "$HOME/.cache/stylusclear_entity_sandbox/activate_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cache/stylusclear_entity_sandbox/activate_env.sh"
fi

RPC_URL="${RPC_URL:-${SEPOLIA_RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}}"
CHAIN_ID_EXPECTED="${CHAIN_ID_EXPECTED:-421614}"
WASM_FILE="$ROOT_DIR/artifacts/clearing_stylus.wasm"
DEPLOY_JSON="$ROOT_DIR/deployments/${DEPLOY_OUT_NAME:-arbitrum-sepolia.json}"
WEB_DEPLOY_JSON="$ROOT_DIR/web/deployments/${DEPLOY_OUT_NAME:-arbitrum-sepolia.json}"

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "[deploy] ERROR: Set PRIVATE_KEY environment variable before broadcasting." >&2
  exit 1
fi
if [[ ! -f "$WASM_FILE" ]]; then
  echo "[deploy] Building reproducible WASM 1.0 MVP artifact..."
  cargo build --locked --release --target wasm32-unknown-unknown -p clearing-stylus
  python3 scripts/optimize-wasm-mvp.py target/wasm32-unknown-unknown/release/clearing_stylus.wasm "$WASM_FILE"
fi

ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID_EXPECTED" ]]; then
  echo "[deploy] FATAL: RPC returned chainId=$ACTUAL_CHAIN_ID (expected $CHAIN_ID_EXPECTED). Aborting to prevent wrong-chain broadcast." >&2
  exit 1
fi

DEPLOYER_ADDR="$(cast wallet address --private-key "$PRIVATE_KEY")"
echo "[deploy] Broadcasting from $DEPLOYER_ADDR to $RPC_URL (chainId=$ACTUAL_CHAIN_ID)..."

deploy_contract() {
  local contract_spec="$1"
  shift
  local solc_opt=()
  if command -v solc >/dev/null 2>&1; then solc_opt=(--use "$(command -v solc)"); fi
  forge create "$contract_spec" "${solc_opt[@]}" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast "$@" --json | python3 -c "import sys,json; print(json.load(sys.stdin)['deployedTo'])"
}

TOK0="$(deploy_contract contracts/src/MockERC20.sol:MockERC20 --constructor-args "USD Coin Mock" "USDC" 6)"
TOK1="$(deploy_contract contracts/src/MockERC20.sol:MockERC20 --constructor-args "Wrapped Ether Mock" "WETH" 18)"
TOK2="$(deploy_contract contracts/src/MockERC20.sol:MockERC20 --constructor-args "Arbitrum Mock" "ARB" 18)"
TOK3="$(deploy_contract contracts/src/MockERC20.sol:MockERC20 --constructor-args "Tokenized NVDAx Mock" "NVDAx" 18)"
FACTORY_ADDR="$(deploy_contract contracts/src/StylusAtomicFactory.sol:StylusAtomicFactory)"
SOL_ENGINE="$(deploy_contract contracts/src/SolidityClearingBenchmark.sol:SolidityClearingBenchmark --constructor-args "$DEPLOYER_ADDR" false)"
cast send "$SOL_ENGINE" "setRiskWindows(uint64,uint16,bool)" 3600 2000 true --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$SOL_ENGINE" "setApprovedSolver(address,bool)" "$DEPLOYER_ADDR" true --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$SOL_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 0 "$TOK0" 6 1000000000000000000 0 500 250 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$SOL_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 1 "$TOK1" 18 2850000000000000000000 500 1000 500 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$SOL_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 2 "$TOK2" 18 1000000000000000000 1000 1200 600 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$SOL_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 3 "$TOK3" 18 140000000000000000000 1000 1200 600 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null

REQUIRE_STYLUS="${REQUIRE_STYLUS:-1}"
STYLUS_ENGINE=""
if command -v cargo-stylus >/dev/null 2>&1 || cargo stylus --version >/dev/null 2>&1; then
  echo "[deploy] Deploying pre-optimized WASM ($WASM_FILE) via cargo stylus --wasm-file..."
  STYLUS_OUT="$(cargo stylus deploy --endpoint "$RPC_URL" --private-key "$PRIVATE_KEY" --wasm-file "$WASM_FILE" --no-verify 2>&1)"
  STYLUS_ENGINE="$(printf '%s\n' "$STYLUS_OUT" | grep -iE 'deployed code at address|contract address' | grep -Eo '0x[0-9a-fA-F]{40}' | head -n 1 || true)"
  if [[ -z "$STYLUS_ENGINE" ]]; then
    STYLUS_ENGINE="$(printf '%s\n' "$STYLUS_OUT" | grep -Eo '\b0x[0-9a-fA-F]{40}\b' | head -n 1 || true)"
  fi
  if [[ -z "$STYLUS_ENGINE" && "$REQUIRE_STYLUS" == "1" ]]; then
  echo "[ERROR] Failed to parse deployed Stylus engine address from cargo stylus deploy output" >&2
  exit 1
fi
if [[ -n "$STYLUS_ENGINE" ]]; then
    cast send "$STYLUS_ENGINE" "initialize(address,bool)" "$DEPLOYER_ADDR" false --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
    cast send "$STYLUS_ENGINE" "setRiskWindows(uint64,uint16,bool)" 3600 2000 true --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
    cast send "$STYLUS_ENGINE" "setApprovedSolver(address,bool)" "$DEPLOYER_ADDR" true --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
    cast send "$STYLUS_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 0 "$TOK0" 6 1000000000000000000 0 500 250 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
    cast send "$STYLUS_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 1 "$TOK1" 18 2850000000000000000000 500 1000 500 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
    cast send "$STYLUS_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 2 "$TOK2" 18 1000000000000000000 1000 1200 600 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
    cast send "$STYLUS_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 3 "$TOK3" 18 140000000000000000000 1000 1200 600 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
  fi
fi

python3 - "$DEPLOY_JSON" "$WEB_DEPLOY_JSON" "$FACTORY_ADDR" "$STYLUS_ENGINE" "$SOL_ENGINE" "$TOK0" "$TOK1" "$TOK2" "$TOK3" <<'PYEOF'
import json, sys
for p in (sys.argv[1], sys.argv[2]):
    d = json.load(open(p, encoding="utf-8"))
    d["schemaVersion"] = "0.9.0"
    d["atomicFactoryContract"] = sys.argv[3]
    d["stylusEngineAddress"] = sys.argv[4] or d.get("stylusEngineAddress")
    d["solidityBenchmarkAddress"] = sys.argv[5]
    keys = list(d["assets"].keys())
    for idx, k in enumerate(keys[:4]):
        d["assets"][k] = sys.argv[6 + idx]
    open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2) + "\n")
PYEOF

echo "[deploy] OK solidity=$SOL_ENGINE stylus=${STYLUS_ENGINE:-pending-stylus-cli} factory=$FACTORY_ADDR"
