#!/usr/bin/env bash
set -euo pipefail

# StylusClear v1.2.0 Idempotent Atomic Deployment Script (robinhood-testnet)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RPC_URL="${ROBINHOOD_RPC_URL:-${SEPOLIA_RPC_URL:-https://rpc.testnet.chain.robinhood.com}}"
CHAIN_ID_EXPECTED="${CHAIN_ID_EXPECTED:-46630}"
DEPLOY_OUT_NAME="${DEPLOY_OUT_NAME:-robinhood-testnet.json}"
REQUIRE_STYLUS="${REQUIRE_STYLUS:-1}"
USE_ATOMIC_FACTORY="${USE_ATOMIC_FACTORY:-1}"

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "[deploy] ERROR: PRIVATE_KEY env var is required." >&2
  exit 1
fi
export ETH_PRIVATE_KEY="$PRIVATE_KEY"
command -v cast >/dev/null 2>&1 || { echo "[deploy] ERROR: Foundry 'cast' required on PATH." >&2; exit 1; }

ACTUAL_CHAIN="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$ACTUAL_CHAIN" != "$CHAIN_ID_EXPECTED" ]]; then
  echo "[deploy] ERROR: Expected chain ID $CHAIN_ID_EXPECTED, got $ACTUAL_CHAIN" >&2
  exit 1
fi

DEPLOYER_ADDR="$(cast wallet address)"
OUT_JSON="$ROOT_DIR/deployments/$DEPLOY_OUT_NAME"
WEB_JSON="$ROOT_DIR/web/deployments/$DEPLOY_OUT_NAME"
COMPILED_JSON="$ROOT_DIR/artifacts/contracts-compiled.json"
INITCODE_HEX_FILE="$ROOT_DIR/artifacts/clearing_stylus.initcode.hex"

echo "[deploy] Network=robinhood-testnet (chainId=$ACTUAL_CHAIN) deployer=$DEPLOYER_ADDR"

read_checkpoint() {
  python3 - "$OUT_JSON" "$1" <<'PYEOF'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.exists():
    print("")
    raise SystemExit(0)
d = json.loads(p.read_text(encoding="utf-8"))
cur = d
for part in sys.argv[2].split("."):
    cur = cur.get(part) if isinstance(cur, dict) else None
print(cur if isinstance(cur, str) else "")
PYEOF
}

write_checkpoint() {
  python3 - "$OUT_JSON" "$WEB_JSON" "$1" "$2" "$ACTUAL_CHAIN" "$RPC_URL" <<'PYEOF'
import json, sys
from pathlib import Path
p, wp, key_path, val, cid, rpc = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6]
d = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {"schemaVersion": "1.2.0", "chainId": cid, "rpcUrl": rpc, "assets": {}}
d["schemaVersion"] = "1.2.0"
d["chainId"] = cid
d["rpcUrl"] = rpc
parts = key_path.split(".")
cur = d
for part in parts[:-1]:
    cur = cur.setdefault(part, {})
cur[parts[-1]] = val
text = json.dumps(d, indent=2) + "\n"
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(text, encoding="utf-8")
wp.parent.mkdir(parents=True, exist_ok=True)
wp.write_text(text, encoding="utf-8")
PYEOF
}

is_deployed() {
  local addr="$1"
  [[ -n "$addr" && "$addr" != "null" && "$addr" != "0x0000000000000000000000000000000000000000" ]] || return 1
  local code
  code="$(cast code "$addr" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")"
  [[ "$code" != "0x" && ${#code} -gt 4 ]]
}

deploy_from_compiled() {
  local contract_name="$1"
  local ctor_sig="$2"
  shift 2
  local bc
  bc="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["bytecode"])' "$COMPILED_JSON" "$contract_name")"
  local encoded_args=""
  if [[ -n "$ctor_sig" ]]; then
    encoded_args="$(cast abi-encode "$ctor_sig" "$@" | sed 's/^0x//')"
  fi
  local create_data="${bc}${encoded_args}"
  local tx_out
  tx_out="$(cast send --rpc-url "$RPC_URL" --json --create "$create_data")"
  printf '%s' "$tx_out" | python3 -c "import json,sys; print(json.load(sys.stdin)['contractAddress'])"
}

ensure_contract() {
  local ck_key="$1"
  local contract_name="$2"
  local ctor_sig="$3"
  shift 3
  local existing
  existing="$(read_checkpoint "$ck_key")"
  if is_deployed "$existing"; then
    echo "[deploy] Reusing checkpointed $ck_key = $existing" >&2
    printf '%s\n' "$existing"
    return 0
  fi
  local deployed
  deployed="$(deploy_from_compiled "$contract_name" "$ctor_sig" "$@")"
  write_checkpoint "$ck_key" "$deployed"
  echo "[deploy] Deployed $ck_key = $deployed" >&2
  printf '%s\n' "$deployed"
}

TOK0="$(ensure_contract "assets.USDG" "MockERC20" "constructor(string,string,uint8)" "USDG" "USDG" 6)"
TOK1="$(ensure_contract "assets.WETH" "MockERC20" "constructor(string,string,uint8)" "Wrapped Ether" "WETH" 18)"
TOK2="$(ensure_contract "assets.ARB" "MockERC20" "constructor(string,string,uint8)" "Arbitrum" "ARB" 18)"
TOK3="$(ensure_contract "assets.NVDAx" "MockERC20" "constructor(string,string,uint8)" "NVIDIA RWA" "NVDAx" 18)"
SOL_ENGINE="$(ensure_contract "solidityBenchmarkAddress" "SolidityClearingBenchmark" "constructor(address,bool)" "$DEPLOYER_ADDR" false)"
FACTORY_ADDR="$(ensure_contract "stylusAtomicFactoryAddress" "StylusAtomicFactory" "")"

STYLUS_ENGINE="$(read_checkpoint "stylusEngineAddress")"
if is_deployed "$STYLUS_ENGINE"; then
  echo "[deploy] Reusing checkpointed stylusEngineAddress = $STYLUS_ENGINE"
else
  if [[ "$USE_ATOMIC_FACTORY" == "1" ]]; then
    if [[ ! -f "$INITCODE_HEX_FILE" ]]; then
      echo "[deploy] ERROR: Missing precompiled $INITCODE_HEX_FILE" >&2
      exit 1
    fi
    INITCODE="$(tr -d '[:space:]' < "$INITCODE_HEX_FILE")"
    SALT="0x$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    TOPIC0="$(cast keccak 'EngineAtomicallyDeployed(address,address,bytes32,bool,bool)')"
    echo "[deploy] Deploying + activating Stylus engine atomically via StylusAtomicFactory ($FACTORY_ADDR)..."
    TX_JSON="$(cast send "$FACTORY_ADDR" "deployAndInitialize(bytes,bytes32,address,bool)" "$INITCODE" "$SALT" "$DEPLOYER_ADDR" false --value 0.002ether --rpc-url "$RPC_URL" --json)"
    STYLUS_ENGINE="$(printf '%s' "$TX_JSON" | python3 - "$TOPIC0" <<'PYEOF'
import json, sys
topic0 = sys.argv[1].lower()
d = json.load(sys.stdin)
for log in d.get("logs", []):
    topics = log.get("topics", [])
    if topics and topics[0].lower() == topic0 and len(topics) >= 2:
        print("0x" + topics[1][-40:])
        raise SystemExit(0)
raise SystemExit("EngineAtomicallyDeployed event not found in receipt logs")
PYEOF
)"
    write_checkpoint "stylusEngineAddress" "$STYLUS_ENGINE"
    echo "[deploy] Atomically deployed & initialized stylusEngineAddress = $STYLUS_ENGINE"
  else
    echo "[deploy] ERROR: USE_ATOMIC_FACTORY=0 is blocked on public testnets to prevent initialize() front-running." >&2
    exit 1
  fi
fi

if [[ "$REQUIRE_STYLUS" == "1" ]] && ! is_deployed "$STYLUS_ENGINE"; then
  echo "[deploy] ERROR: REQUIRE_STYLUS=1 but stylusEngineAddress is not deployed." >&2
  exit 1
fi

for ENG in "$SOL_ENGINE" "$STYLUS_ENGINE"; do
  is_deployed "$ENG" || continue
  COUNT="$(cast call "$ENG" "assetCount()(uint8)" --rpc-url "$RPC_URL" 2>/dev/null || echo 0)"
  if [[ "$COUNT" -lt 4 ]]; then
    echo "[deploy] Configuring 4 institutional assets on $ENG..."
    cast send "$ENG" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 0 "$TOK0" 6 1000000000000000000 0 500 250 --rpc-url "$RPC_URL" >/dev/null
    cast send "$ENG" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 1 "$TOK1" 18 2850000000000000000000 1000 1000 500 --rpc-url "$RPC_URL" >/dev/null
    cast send "$ENG" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 2 "$TOK2" 18 1100000000000000000 2000 1500 750 --rpc-url "$RPC_URL" >/dev/null
    cast send "$ENG" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 3 "$TOK3" 18 140000000000000000000 1500 1200 600 --rpc-url "$RPC_URL" >/dev/null
  fi
done

echo "[deploy] DONE (robinhood-testnet): Solidity=$SOL_ENGINE | Stylus=$STYLUS_ENGINE"
