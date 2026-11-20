#!/usr/bin/env bash
set -euo pipefail

# StylusClear v1.2.0 Idempotent Live Settlement & 4-Asset Seeding Script
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
  NET_KEY="robinhood_testnet"
else
  DEPLOY_JSON="$ROOT_DIR/deployments/arbitrum-sepolia.json"
  RPC_URL="${ARB_SEPOLIA_RPC_URL:-${SEPOLIA_RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}}"
  NET_KEY="arbitrum_sepolia"
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "[demo-live] ERROR: PRIVATE_KEY is required to broadcast live demo settlement." >&2
  exit 1
fi
export ETH_PRIVATE_KEY="$PRIVATE_KEY"

read -r SOL_ENGINE STYLUS_ADDR TOK0 TOK3 < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
vals = list(d["assets"].values())
print(
    d.get("solidityBenchmarkAddress") or "",
    d.get("stylusEngineAddress") or "null",
    vals[0] or "",
    vals[3] or "",
)
' "$DEPLOY_JSON")

if [[ -z "$SOL_ENGINE" || -z "$TOK0" || -z "$TOK3" ]]; then
  echo "[demo-live] ERROR: Contracts not yet deployed in $DEPLOY_JSON." >&2
  exit 1
fi

CALLER="$(cast wallet address)"
COUNTERPARTY="0x2222222222222222222222222222222222222222"

cast send "$TOK0" "mint(address,uint256)" "$CALLER" 50000000000 --rpc-url "$RPC_URL" >/dev/null
cast send "$TOK0" "approve(address,uint256)" "$SOL_ENGINE" 50000000000 --rpc-url "$RPC_URL" >/dev/null
cast send "$SOL_ENGINE" "deposit(uint8,uint256)" 0 25000000000 --rpc-url "$RPC_URL" >/dev/null

cast send "$TOK3" "mint(address,uint256)" "$CALLER" 100000000000000000000 --rpc-url "$RPC_URL" >/dev/null
cast send "$TOK3" "approve(address,uint256)" "$SOL_ENGINE" 100000000000000000000 --rpc-url "$RPC_URL" >/dev/null
cast send "$SOL_ENGINE" "deposit(uint8,uint256)" 3 50000000000000000000 --rpc-url "$RPC_URL" >/dev/null

cast send "$SOL_ENGINE" "registerObligation(address,uint8,uint256)" "$COUNTERPARTY" 0 250000000000000000000 --rpc-url "$RPC_URL" >/dev/null
TX_JSON="$(cast send "$SOL_ENGINE" "settleBatch(address[],(uint16,uint16,uint8,uint8,uint8,uint64,uint256,uint256,bytes32,bytes32)[],(uint16,uint8,uint8,uint8,uint8,uint8,uint64,uint256,uint256,uint256,bytes32,bytes32)[])" "[$CALLER,$COUNTERPARTY]" "[(0,1,0,0,0,1000000,250000000000000000000,0,0x0000000000000000000000000000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000000000000000000000000000)]" "[]" --rpc-url "$RPC_URL" --json)"
TX_HASH="$(printf '%s' "$TX_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")"
echo "[demo-live] Settled Solidity batch tx=$TX_HASH on $TARGET_NET"

STYLUS_TX_HASH=""
STYLUS_ADDR_CLEAN=""
if [[ -n "${STYLUS_ADDR:-}" && "$STYLUS_ADDR" != "null" ]]; then
  STYLUS_ADDR_CLEAN="$STYLUS_ADDR"
  echo "[demo-live] Executing live settleBatch on Stylus engine: $STYLUS_ADDR_CLEAN"
  cast send "$TOK0" "approve(address,uint256)" "$STYLUS_ADDR_CLEAN" 50000000000 --rpc-url "$RPC_URL" >/dev/null
  cast send "$STYLUS_ADDR_CLEAN" "deposit(uint8,uint256)" 0 25000000000 --rpc-url "$RPC_URL" >/dev/null
  cast send "$STYLUS_ADDR_CLEAN" "registerObligation(address,uint8,uint256)" "$COUNTERPARTY" 0 250000000000000000000 --rpc-url "$RPC_URL" >/dev/null
  STYLUS_TX_HASH="$(cast send "$STYLUS_ADDR_CLEAN" "settleBatch(address[],(uint16,uint16,uint8,uint8,uint8,uint64,uint256,uint256,bytes32,bytes32)[],(uint16,uint8,uint8,uint8,uint8,uint8,uint64,uint256,uint256,uint256,bytes32,bytes32)[])" \
    "[$CALLER,$COUNTERPARTY]" "[(0,1,0,0,0,1000000,250000000000000000000,0,0x0000000000000000000000000000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000000000000000000000000000)]" "[]" \
    --rpc-url "$RPC_URL" --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('transactionHash',''))")"
  echo "[demo-live] Stylus settleBatch tx=${STYLUS_TX_HASH:-skipped}"
fi

python3 - "$DEPLOY_JSON" "$ROOT_DIR/web/deployments/$(basename "$DEPLOY_JSON")" "${TX_HASH:-}" "${STYLUS_TX_HASH:-}" <<'PYEOF'
import json, sys
from pathlib import Path

p = Path(sys.argv[1])
web_p = Path(sys.argv[2])
if p.exists():
    d = json.loads(p.read_text(encoding="utf-8"))
    hashes = [h for h in d.get("verifiedTxHashes", []) if h]
    for h in sys.argv[3:]:
        if h and h not in hashes:
            hashes.append(h)
    d["verifiedTxHashes"] = hashes
    serialized = json.dumps(d, indent=2) + "\n"
    p.write_text(serialized, encoding="utf-8")
    if web_p.parent.exists():
        web_p.write_text(serialized, encoding="utf-8")
PYEOF

if [[ -n "${STYLUS_TX_HASH:-}" || -n "${TX_HASH:-}" ]]; then
  SOL_GAS="$(cast receipt "${TX_HASH:-}" --rpc-url "$RPC_URL" --json 2>/dev/null | python3 -c "import sys,json; r=json.load(sys.stdin); print(int(str(r['gasUsed']),0))" 2>/dev/null || echo "")"
  STY_GAS="$(cast receipt "${STYLUS_TX_HASH:-}" --rpc-url "$RPC_URL" --json 2>/dev/null | python3 -c "import sys,json; r=json.load(sys.stdin); print(int(str(r['gasUsed']),0))" 2>/dev/null || echo "")"
  python3 - "$NET_KEY" "$SOL_ENGINE" "$STYLUS_ADDR_CLEAN" "${TX_HASH:-}" "${STYLUS_TX_HASH:-}" "$SOL_GAS" "$STY_GAS" <<'PYEOF'
import json, sys
from pathlib import Path
p = Path("docs/benchmarks/measured-gas-artifacts.json")
if p.exists():
    d = json.loads(p.read_text(encoding="utf-8"))
    ov = d.setdefault("onchain_verification", {})
    net_key = sys.argv[1]
    rec = ov.setdefault(net_key, {})
    if sys.argv[2]: rec["solidity_contract_address"] = sys.argv[2]
    if sys.argv[3]: rec["stylus_contract_address"] = sys.argv[3]
    if sys.argv[4]: rec["solidity_settle_tx_hash"] = sys.argv[4]
    if sys.argv[5]: rec["stylus_settle_tx_hash"] = sys.argv[5]
    if sys.argv[6]: rec["solidity_receipt_gas_used"] = int(sys.argv[6])
    if sys.argv[7]: rec["stylus_receipt_gas_used"] = int(sys.argv[7])
    if net_key == "arbitrum_sepolia":
        if sys.argv[5] or sys.argv[4]: ov["arbitrum_sepolia_tx"] = sys.argv[5] or sys.argv[4]
        if sys.argv[7]: ov["arbitrum_sepolia_stylus_gas"] = int(sys.argv[7])
        if sys.argv[6]: ov["arbitrum_sepolia_solidity_gas"] = int(sys.argv[6])
    elif net_key == "robinhood_testnet":
        if sys.argv[5] or sys.argv[4]: ov["robinhood_testnet_tx"] = sys.argv[5] or sys.argv[4]
    if ov.get("arbitrum_sepolia_tx") and ov.get("robinhood_testnet_tx"):
        d["calibration_status"] = "dual_chain_onchain_verified"
    elif ov.get("arbitrum_sepolia_tx"):
        d["calibration_status"] = "arbitrum_sepolia_onchain_verified"
    p.write_text(json.dumps(d, indent=2) + "\n", encoding="utf-8", newline="\n")
PYEOF
  python3 scripts/generate-benchmarks.py --render-from-json
fi
