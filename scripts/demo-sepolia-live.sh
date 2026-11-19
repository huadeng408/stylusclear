#!/usr/bin/env bash
set -euo pipefail

# StylusClear v0.7.0 Idempotent Live Settlement & 4-Asset Seeding Script
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f "$HOME/.cache/stylusclear_entity_sandbox/activate_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cache/stylusclear_entity_sandbox/activate_env.sh"
fi

TARGET_NET="${1:-sepolia}"
if [[ "$TARGET_NET" == "robinhood" ]]; then
  DEPLOY_JSON="$ROOT_DIR/deployments/robinhood-testnet.json"
  RPC_URL="${ROBINHOOD_RPC_URL:-https://rpc.testnet.chain.robinhood.com}"
else
  DEPLOY_JSON="$ROOT_DIR/deployments/arbitrum-sepolia.json"
  RPC_URL="${SEPOLIA_RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}"
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "[demo-live] ERROR: PRIVATE_KEY is required to broadcast live demo settlement." >&2
  exit 1
fi

read -r SOL_ENGINE TOK0 TOK3 < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
vals = list(d["assets"].values())
print(d.get("solidityBenchmarkAddress") or "", vals[0] or "", vals[3] or "")
' "$DEPLOY_JSON")

if [[ -z "$SOL_ENGINE" || -z "$TOK0" || -z "$TOK3" ]]; then
  echo "[demo-live] ERROR: Contracts not yet deployed in $DEPLOY_JSON." >&2
  exit 1
fi

CALLER="$(cast wallet address --private-key "$PRIVATE_KEY")"
COUNTERPARTY="0x2222222222222222222222222222222222222222"

cast send "$TOK0" "mint(address,uint256)" "$CALLER" 50000000000 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$TOK0" "approve(address,uint256)" "$SOL_ENGINE" 50000000000 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$SOL_ENGINE" "deposit(uint8,uint256)" 0 25000000000 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null

cast send "$TOK3" "mint(address,uint256)" "$CALLER" 100000000000000000000 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$TOK3" "approve(address,uint256)" "$SOL_ENGINE" 100000000000000000000 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$SOL_ENGINE" "deposit(uint8,uint256)" 3 50000000000000000000 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null

cast send "$SOL_ENGINE" "registerObligation(address,uint8,uint256)" "$COUNTERPARTY" 0 250000000000000000000 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
TX_JSON="$(cast send "$SOL_ENGINE" "settleBatch(address[],(uint16,uint16,uint8,uint8,uint8,uint64,uint256,uint256,bytes32,bytes32)[],(uint16,uint8,uint8,uint8,uint8,uint8,uint64,uint256,uint256,uint256,bytes32,bytes32)[])" "[$CALLER,$COUNTERPARTY]" "[(0,1,0,0,0,1000000,250000000000000000000,0,0x0000000000000000000000000000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000000000000000000000000000)]" "[]" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --json)"
TX_HASH="$(printf '%s' "$TX_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")"
echo "[demo-live] Settled batch tx=$TX_HASH on $TARGET_NET"
