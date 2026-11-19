#!/usr/bin/env bash
set -euo pipefail

# StylusClear v1.1.0 Atomic Deployment Script (Arbitrum Sepolia — Chain ID 421614)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f "$HOME/.cache/stylusclear_entity_sandbox/activate_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cache/stylusclear_entity_sandbox/activate_env.sh"
fi

RPC_URL="${RPC_URL:-${SEPOLIA_RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}}"
CHAIN_ID_EXPECTED="${CHAIN_ID_EXPECTED:-421614}"
WASM_FILE="$ROOT_DIR/artifacts/clearing_stylus.wasm"
INITCODE_HEX_FILE="$ROOT_DIR/artifacts/clearing_stylus.initcode.hex"
DEPLOY_JSON="$ROOT_DIR/deployments/${DEPLOY_OUT_NAME:-arbitrum-sepolia.json}"
WEB_DEPLOY_JSON="$ROOT_DIR/web/deployments/${DEPLOY_OUT_NAME:-arbitrum-sepolia.json}"
REQUIRE_STYLUS="${REQUIRE_STYLUS:-1}"
USE_ATOMIC_FACTORY="${USE_ATOMIC_FACTORY:-1}"

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "[deploy] ERROR: Set PRIVATE_KEY environment variable before broadcasting." >&2
  exit 1
fi
export ETH_PRIVATE_KEY="$PRIVATE_KEY"

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

DEPLOYER_ADDR="$(cast wallet address)"
echo "[deploy] Broadcasting from $DEPLOYER_ADDR to $RPC_URL (chainId=$ACTUAL_CHAIN_ID)..."

deploy_contract() {
  local contract_spec="$1"
  shift
  local solc_opt=()
  if command -v solc >/dev/null 2>&1; then solc_opt=(--use "$(command -v solc)"); fi
  forge create "$contract_spec" "${solc_opt[@]}" --rpc-url "$RPC_URL" --broadcast "$@" --json | python3 -c "import sys,json; print(json.load(sys.stdin)['deployedTo'])"
}

TOK0="$(deploy_contract contracts/src/MockERC20.sol:MockERC20 --constructor-args "USD Coin Mock" "USDC" 6)"
TOK1="$(deploy_contract contracts/src/MockERC20.sol:MockERC20 --constructor-args "Wrapped Ether Mock" "WETH" 18)"
TOK2="$(deploy_contract contracts/src/MockERC20.sol:MockERC20 --constructor-args "Arbitrum Mock" "ARB" 18)"
TOK3="$(deploy_contract contracts/src/MockERC20.sol:MockERC20 --constructor-args "Tokenized NVDAx Mock" "NVDAx" 18)"
FACTORY_ADDR="$(deploy_contract contracts/src/StylusAtomicFactory.sol:StylusAtomicFactory)"
SOL_ENGINE="$(deploy_contract contracts/src/SolidityClearingBenchmark.sol:SolidityClearingBenchmark --constructor-args "$DEPLOYER_ADDR" false)"

cast send "$SOL_ENGINE" "setRiskWindows(uint64,uint16,bool)" 3600 2000 true --rpc-url "$RPC_URL" >/dev/null
cast send "$SOL_ENGINE" "setApprovedSolver(address,bool)" "$DEPLOYER_ADDR" true --rpc-url "$RPC_URL" >/dev/null
cast send "$SOL_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 0 "$TOK0" 6 1000000000000000000 0 500 250 --rpc-url "$RPC_URL" >/dev/null
cast send "$SOL_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 1 "$TOK1" 18 2850000000000000000000 500 1000 500 --rpc-url "$RPC_URL" >/dev/null
cast send "$SOL_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 2 "$TOK2" 18 1000000000000000000 1000 1200 600 --rpc-url "$RPC_URL" >/dev/null
cast send "$SOL_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 3 "$TOK3" 18 140000000000000000000 1000 1200 600 --rpc-url "$RPC_URL" >/dev/null

STYLUS_ENGINE=""
if [[ "$USE_ATOMIC_FACTORY" == "1" && -f "$INITCODE_HEX_FILE" ]]; then
  echo "[deploy] Atomically deploying & initializing Stylus engine via StylusAtomicFactory ($FACTORY_ADDR)..."
  INITCODE_HEX="$(tr -d '\r\n' < "$INITCODE_HEX_FILE")"
  USER_SALT="$(cast keccak "stylusclear-v1.1.0-$(date +%s)")"
  FAC_TX_JSON="$(cast send "$FACTORY_ADDR" "deployAndInitialize(bytes,bytes32,address,bool)" "$INITCODE_HEX" "$USER_SALT" "$DEPLOYER_ADDR" false --value 0.002ether --rpc-url "$RPC_URL" --json)"
  STYLUS_ENGINE="$(printf '%s' "$FAC_TX_JSON" | python3 -c "import sys,json; logs=json.load(sys.stdin).get('logs',[]); print('0x'+logs[-1]['topics'][1][-40:] if logs and len(logs[-1].get('topics',[]))>1 else '')")"
elif command -v cargo-stylus >/dev/null 2>&1 || cargo stylus --version >/dev/null 2>&1; then
  echo "[deploy] Deploying pre-optimized WASM ($WASM_FILE) via cargo stylus --private-key-path..."
  KEY_TMP="$(mktemp)"
  chmod 600 "$KEY_TMP"
  trap 'rm -f "$KEY_TMP"' EXIT
  printf '%s' "$PRIVATE_KEY" > "$KEY_TMP"
  STYLUS_OUT="$(cargo stylus deploy --endpoint "$RPC_URL" --private-key-path "$KEY_TMP" --wasm-file "$WASM_FILE" --no-verify 2>&1 | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
  rm -f "$KEY_TMP"
  STYLUS_ENGINE="$(printf '%s\n' "$STYLUS_OUT" | grep -iE 'deployed code at address|contract address' | grep -Eo '0x[0-9a-fA-F]{40}' | head -n 1 || true)"
  if [[ -n "$STYLUS_ENGINE" ]]; then
    cast send "$STYLUS_ENGINE" "initialize(address,bool)" "$DEPLOYER_ADDR" false --rpc-url "$RPC_URL" >/dev/null
  fi
fi

if [[ -z "$STYLUS_ENGINE" && "$REQUIRE_STYLUS" == "1" ]]; then
  echo "[ERROR] Stylus engine deployment failed or cargo-stylus/initcode unavailable while REQUIRE_STYLUS=1" >&2
  exit 1
fi

if [[ -n "$STYLUS_ENGINE" ]]; then
  cast send "$STYLUS_ENGINE" "setRiskWindows(uint64,uint16,bool)" 3600 2000 true --rpc-url "$RPC_URL" >/dev/null
  cast send "$STYLUS_ENGINE" "setApprovedSolver(address,bool)" "$DEPLOYER_ADDR" true --rpc-url "$RPC_URL" >/dev/null
  cast send "$STYLUS_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 0 "$TOK0" 6 1000000000000000000 0 500 250 --rpc-url "$RPC_URL" >/dev/null
  cast send "$STYLUS_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 1 "$TOK1" 18 2850000000000000000000 500 1000 500 --rpc-url "$RPC_URL" >/dev/null
  cast send "$STYLUS_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 2 "$TOK2" 18 1000000000000000000 1000 1200 600 --rpc-url "$RPC_URL" >/dev/null
  cast send "$STYLUS_ENGINE" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 3 "$TOK3" 18 140000000000000000000 1000 1200 600 --rpc-url "$RPC_URL" >/dev/null
fi

python3 - "$DEPLOY_JSON" "$WEB_DEPLOY_JSON" "$FACTORY_ADDR" "$STYLUS_ENGINE" "$SOL_ENGINE" "$TOK0" "$TOK1" "$TOK2" "$TOK3" "$ACTUAL_CHAIN_ID" "$RPC_URL" <<'PYEOF'
import json, sys
from pathlib import Path

for p_str in (sys.argv[1], sys.argv[2]):
    p = Path(p_str)
    if p.exists():
        d = json.loads(p.read_text(encoding="utf-8"))
    else:
        p.parent.mkdir(parents=True, exist_ok=True)
        d = {
            "schemaVersion": "1.1.0",
            "chainId": int(sys.argv[10]),
            "rpcUrl": sys.argv[11],
            "assets": {"USDC": None, "WETH": None, "ARB": None, "NVDAx": None},
            "verifiedTxHashes": [],
        }
    d["schemaVersion"] = "1.1.0"
    d["atomicFactoryContract"] = sys.argv[3]
    d["stylusEngineAddress"] = sys.argv[4] or d.get("stylusEngineAddress")
    d["solidityBenchmarkAddress"] = sys.argv[5]
    keys = list(d["assets"].keys())
    for idx, k in enumerate(keys[:4]):
        d["assets"][k] = sys.argv[6 + idx]
    p.write_text(json.dumps(d, indent=2) + "\n", encoding="utf-8", newline="\n")
PYEOF

echo "[deploy] OK solidity=$SOL_ENGINE stylus=${STYLUS_ENGINE:-pending-stylus-cli} factory=$FACTORY_ADDR"
