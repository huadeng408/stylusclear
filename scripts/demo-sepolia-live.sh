#!/usr/bin/env bash
set -euo pipefail

# StylusClear v1.2.0 Idempotent Live Settlement & 4-Asset Seeding Script
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=scripts/deploy-common.sh
source "$ROOT_DIR/scripts/deploy-common.sh"

TARGET_NET="${1:-sepolia}"
if [[ "$TARGET_NET" == "robinhood" ]]; then
  DEPLOY_OUT_NAME="robinhood-testnet.json"
  RPC_URL="${ROBINHOOD_RPC_URL:-https://rpc.testnet.chain.robinhood.com}"
  NET_KEY="robinhood_testnet"
else
  DEPLOY_OUT_NAME="arbitrum-sepolia.json"
  RPC_URL="${ARB_SEPOLIA_RPC_URL:-${SEPOLIA_RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}}"
  NET_KEY="arbitrum_sepolia"
fi
OUT_JSON="$ROOT_DIR/deployments/$DEPLOY_OUT_NAME"
WEB_JSON="$ROOT_DIR/web/deployments/$DEPLOY_OUT_NAME"

setup_ephemeral_keystore

read -r SOL_ENGINE STYLUS_ADDR TOK0 TOK3 < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assets = d.get("assets", {})
tok0 = assets.get("usdcMock6") or assets.get("usdgMock6") or ""
tok3 = assets.get("rwaMock18") or assets.get("nvdaxMock18") or ""
print(
    d.get("solidityBenchmarkAddress") or "null",
    d.get("stylusEngineAddress") or "null",
    tok0 or "null",
    tok3 or "null",
)
' "$OUT_JSON")

if [[ "$SOL_ENGINE" == "null" || "$TOK0" == "null" || "$TOK3" == "null" ]]; then
  echo "[demo-live] ERROR: Contracts not yet deployed in $OUT_JSON." >&2
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

# Register 1,250 USD confirmed obligation (consumes 250 in authMode=0 live tx, leaves 1,000 confirmed for solver probes)
cast send "$SOL_ENGINE" "registerObligation(address,uint8,uint256)" "$COUNTERPARTY" 0 1250000000000000000000 --rpc-url "$RPC_URL" >/dev/null
NONCE_SOL="$(python3 -c 'import secrets; print((secrets.randbits(48) << 8) + 1)')"
TX_JSON="$(cast send "$SOL_ENGINE" "settleBatch(address[],(uint16,uint16,uint8,uint8,uint8,uint64,uint256,uint256,bytes32,bytes32)[],(uint16,uint8,uint8,uint8,uint8,uint8,uint64,uint256,uint256,uint256,bytes32,bytes32)[])" "[$CALLER,$COUNTERPARTY]" "[(0,1,0,0,0,1000000000,250000000000000000000,$NONCE_SOL,0x0000000000000000000000000000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000000000000000000000000000)]" "[]" --rpc-url "$RPC_URL" --json)"
TX_HASH="$(printf '%s' "$TX_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")"
echo "[demo-live] Settled Solidity batch tx=$TX_HASH on $TARGET_NET"

STYLUS_TX_HASH=""
STYLUS_ADDR_CLEAN=""
if is_deployed "$STYLUS_ADDR"; then
  STYLUS_ADDR_CLEAN="$STYLUS_ADDR"
  echo "[demo-live] Executing live settleBatch on Stylus engine: $STYLUS_ADDR_CLEAN"
  cast send "$TOK0" "approve(address,uint256)" "$STYLUS_ADDR_CLEAN" 50000000000 --rpc-url "$RPC_URL" >/dev/null
  cast send "$STYLUS_ADDR_CLEAN" "deposit(uint8,uint256)" 0 25000000000 --rpc-url "$RPC_URL" >/dev/null
  cast send "$TOK3" "approve(address,uint256)" "$STYLUS_ADDR_CLEAN" 100000000000000000000 --rpc-url "$RPC_URL" >/dev/null
  cast send "$STYLUS_ADDR_CLEAN" "deposit(uint8,uint256)" 3 50000000000000000000 --rpc-url "$RPC_URL" >/dev/null
  cast send "$STYLUS_ADDR_CLEAN" "registerObligation(address,uint8,uint256)" "$COUNTERPARTY" 0 1250000000000000000000 --rpc-url "$RPC_URL" >/dev/null
  NONCE_STY="$(python3 -c 'import secrets; print((secrets.randbits(48) << 8) + 2)')"
  STYLUS_TX_HASH="$(cast send "$STYLUS_ADDR_CLEAN" "settleBatch(address[],(uint16,uint16,uint8,uint8,uint8,uint64,uint256,uint256,bytes32,bytes32)[],(uint16,uint8,uint8,uint8,uint8,uint8,uint64,uint256,uint256,uint256,bytes32,bytes32)[])" \
    "[$CALLER,$COUNTERPARTY]" "[(0,1,0,0,0,1000000000,250000000000000000000,$NONCE_STY,0x0000000000000000000000000000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000000000000000000000000000)]" "[]" \
    --rpc-url "$RPC_URL" --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('transactionHash',''))")"
  echo "[demo-live] Stylus settleBatch tx=${STYLUS_TX_HASH:-skipped}"
fi

SOL_GAS=""
STY_GAS=""
if [[ -n "${TX_HASH:-}" ]]; then
  SOL_GAS="$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" --json 2>/dev/null | python3 -c "import sys,json; r=json.load(sys.stdin); print(int(str(r['gasUsed']),0))" 2>/dev/null || echo "")"
fi
if [[ -n "${STYLUS_TX_HASH:-}" ]]; then
  STY_GAS="$(cast receipt "$STYLUS_TX_HASH" --rpc-url "$RPC_URL" --json 2>/dev/null | python3 -c "import sys,json; r=json.load(sys.stdin); print(int(str(r['gasUsed']),0))" 2>/dev/null || echo "")"
fi

TELEMETRY_NET_KEY="$NET_KEY" \
TELEMETRY_OUT_JSON="$OUT_JSON" \
TELEMETRY_WEB_JSON="$WEB_JSON" \
TELEMETRY_CALLER="$CALLER" \
TELEMETRY_SOL_ENGINE="$SOL_ENGINE" \
TELEMETRY_STY_ENGINE="$STYLUS_ADDR_CLEAN" \
TELEMETRY_SOL_TX="${TX_HASH:-}" \
TELEMETRY_STY_TX="${STYLUS_TX_HASH:-}" \
TELEMETRY_SOL_GAS="$SOL_GAS" \
TELEMETRY_STY_GAS="$STY_GAS" \
python3 - <<'PYEOF'
import json, os
from pathlib import Path

out_p = Path(os.environ["TELEMETRY_OUT_JSON"])
web_p = Path(os.environ["TELEMETRY_WEB_JSON"])
manifest = json.loads(out_p.read_text(encoding="utf-8"))
manifest["demoTraderA"] = os.environ["TELEMETRY_CALLER"]
hashes = [h for h in manifest.get("verifiedTxHashes", []) if h]
for h in (os.environ["TELEMETRY_SOL_TX"], os.environ["TELEMETRY_STY_TX"]):
    if h and h not in hashes:
        hashes.append(h)
manifest["verifiedTxHashes"] = hashes
serialized = json.dumps(manifest, indent=2) + "\n"
out_p.write_text(serialized, encoding="utf-8", newline="\n")
if web_p.parent.exists():
    web_p.write_text(serialized, encoding="utf-8", newline="\n")

art_p = Path("docs/benchmarks/measured-gas-artifacts.json")
if art_p.exists() and (os.environ["TELEMETRY_SOL_TX"] or os.environ["TELEMETRY_STY_TX"]):
    d = json.loads(art_p.read_text(encoding="utf-8"))
    ov = d.setdefault("onchain_verification", {})
    net_key = os.environ["TELEMETRY_NET_KEY"]
    rec = ov.setdefault(net_key, {})
    if os.environ["TELEMETRY_SOL_ENGINE"]:
        rec["solidity_contract_address"] = os.environ["TELEMETRY_SOL_ENGINE"]
    if os.environ["TELEMETRY_STY_ENGINE"]:
        rec["stylus_contract_address"] = os.environ["TELEMETRY_STY_ENGINE"]
    if manifest.get("stylusWasmBytecodeAddress"):
        rec["stylus_wasm_bytecode_address"] = manifest["stylusWasmBytecodeAddress"]
    if manifest.get("stylusActivationStatus"):
        rec["stylus_activation_status"] = manifest["stylusActivationStatus"]
    if os.environ["TELEMETRY_SOL_TX"]:
        rec["solidity_settle_tx_hash"] = os.environ["TELEMETRY_SOL_TX"]
    if os.environ["TELEMETRY_STY_TX"]:
        rec["stylus_settle_tx_hash"] = os.environ["TELEMETRY_STY_TX"]
    if os.environ["TELEMETRY_SOL_GAS"]:
        rec["solidity_receipt_gas_used"] = int(os.environ["TELEMETRY_SOL_GAS"])
    if os.environ["TELEMETRY_STY_GAS"]:
        rec["stylus_receipt_gas_used"] = int(os.environ["TELEMETRY_STY_GAS"])
    primary_tx = os.environ["TELEMETRY_STY_TX"] or os.environ["TELEMETRY_SOL_TX"]
    if net_key == "arbitrum_sepolia":
        if primary_tx:
            ov["arbitrum_sepolia_tx"] = primary_tx
        if os.environ["TELEMETRY_STY_GAS"]:
            ov["arbitrum_sepolia_stylus_gas"] = int(os.environ["TELEMETRY_STY_GAS"])
        if os.environ["TELEMETRY_SOL_GAS"]:
            ov["arbitrum_sepolia_solidity_gas"] = int(os.environ["TELEMETRY_SOL_GAS"])
    elif net_key == "robinhood_testnet" and primary_tx:
        ov["robinhood_testnet_tx"] = primary_tx
    if ov.get("arbitrum_sepolia_tx") and ov.get("robinhood_testnet_tx"):
        d["calibration_status"] = "dual_chain_onchain_verified"
    elif ov.get("arbitrum_sepolia_tx"):
        d["calibration_status"] = "arbitrum_sepolia_onchain_verified"
    art_p.write_text(json.dumps(d, indent=2) + "\n", encoding="utf-8", newline="\n")
PYEOF

if [[ -n "${STYLUS_TX_HASH:-}" || -n "${TX_HASH:-}" ]]; then
  python3 scripts/generate-benchmarks.py --render-from-json
fi
