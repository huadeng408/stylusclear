#!/usr/bin/env bash
# Shared in-memory Foundry keystore & idempotent checkpoint helpers for StylusClear v1.2.0

setup_stylusclear_env() {
  if [[ -f "$HOME/.cache/stylusclear_entity_sandbox/activate_env.sh" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.cache/stylusclear_entity_sandbox/activate_env.sh"
  fi
  export PATH="$HOME/.local/bin:$HOME/.foundry/bin:$HOME/.cargo/bin:/usr/local/bin:$PATH"
}
setup_stylusclear_env

STYLUSCLEAR_TMP_KS=""
OUT_JSON="${OUT_JSON:-}"
WEB_JSON="${WEB_JSON:-}"
ACTUAL_CHAIN="${ACTUAL_CHAIN:-0}"
RPC_URL="${RPC_URL:-}"
CHAIN_ID_EXPECTED="${CHAIN_ID_EXPECTED:-0}"
DEPLOY_OUT_NAME="${DEPLOY_OUT_NAME:-}"
COMPILED_JSON="${COMPILED_JSON:-}"
INITCODE_HEX_FILE="${INITCODE_HEX_FILE:-}"
DEPLOYER_ADDR="${DEPLOYER_ADDR:-}"
REQUIRE_STYLUS="${REQUIRE_STYLUS:-1}"
USE_ATOMIC_FACTORY="${USE_ATOMIC_FACTORY:-1}"
cleanup_ephemeral_keystore() {
  if [[ -n "${STYLUSCLEAR_TMP_KS:-}" && -d "$STYLUSCLEAR_TMP_KS" ]]; then
    rm -rf "$STYLUSCLEAR_TMP_KS"
  fi
}

register_exit_cleanup() {
  local prev_trap
  prev_trap="$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/" || true)"
  if [[ -n "$prev_trap" && "$prev_trap" != *"cleanup_ephemeral_keystore"* ]]; then
    # shellcheck disable=SC2064
    trap "${prev_trap}; cleanup_ephemeral_keystore" EXIT
  elif [[ -z "$prev_trap" ]]; then
    trap cleanup_ephemeral_keystore EXIT
  fi
}

setup_ephemeral_keystore() {
  if [[ -n "${ETH_KEYSTORE:-}" && -f "${ETH_KEYSTORE:-}" ]]; then
    return 0
  fi
  if [[ -z "${PRIVATE_KEY:-}" ]]; then
    echo "[deploy] ERROR: PRIVATE_KEY env var is required." >&2
    exit 1
  fi
  command -v cast >/dev/null 2>&1 || { echo "[deploy] ERROR: Foundry 'cast' required on PATH." >&2; exit 1; }

  STYLUSCLEAR_TMP_KS="$(mktemp -d)"
  chmod 700 "$STYLUSCLEAR_TMP_KS"
  register_exit_cleanup

  python3 - "$ROOT_DIR" "$STYLUSCLEAR_TMP_KS/deployer.json" "$STYLUSCLEAR_TMP_KS/pw" <<'PYEOF'
import json, os, secrets, sys, uuid
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from tools.ref_sim.crypto_eip712 import build_web3_keystore_v3

raw_pk = os.environ["PRIVATE_KEY"].strip()
if raw_pk.startswith(("0x", "0X")):
    raw_pk = raw_pk[2:]
pk_bytes = bytes.fromhex(raw_pk)
if len(pk_bytes) != 32:
    raise SystemExit("PRIVATE_KEY must be a 32-byte hex string")

pw = secrets.token_hex(24)
ks = build_web3_keystore_v3(pk_bytes, pw, os.urandom(32), os.urandom(16), str(uuid.uuid4()))
Path(sys.argv[2]).write_text(json.dumps(ks), encoding="utf-8")
Path(sys.argv[3]).write_text(pw, encoding="utf-8")
os.chmod(sys.argv[2], 0o600)
os.chmod(sys.argv[3], 0o600)
PYEOF

  unset PRIVATE_KEY
  export ETH_KEYSTORE="$STYLUSCLEAR_TMP_KS/deployer.json"
  export ETH_PASSWORD="$STYLUSCLEAR_TMP_KS/pw"
}

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
p, wp, key_path, val_raw, cid, rpc = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6]
d = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {"schemaVersion": "1.2.0", "chainId": cid, "rpcUrl": rpc, "assets": {}}
d["schemaVersion"] = "1.2.0"
d["chainId"] = cid
if not d.get("rpcUrl"):
    d["rpcUrl"] = rpc
val = None if val_raw == "__NULL__" else val_raw
parts = key_path.split(".")
cur = d
for part in parts[:-1]:
    cur = cur.setdefault(part, {})
cur[parts[-1]] = val
text = json.dumps(d, indent=2) + "\n"
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(text, encoding="utf-8", newline="\n")
wp.parent.mkdir(parents=True, exist_ok=True)
wp.write_text(text, encoding="utf-8", newline="\n")
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
  bc="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]]["bytecode"])' "$COMPILED_JSON" "$contract_name")"
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

deploy_or_stage_stylus_engine() {
  local factory_addr="$1"
  local deployer_addr="$2"
  local require_stylus="${3:-1}"
  local use_atomic="${4:-1}"

  local stylus_engine
  stylus_engine="$(read_checkpoint "stylusEngineAddress")"
  if is_deployed "$stylus_engine"; then
    echo "[deploy] Reusing checkpointed stylusEngineAddress = $stylus_engine" >&2
    printf '%s\n' "$stylus_engine"
    return 0
  fi

  if [[ "$use_atomic" != "1" ]]; then
    echo "[deploy] ERROR: USE_ATOMIC_FACTORY=0 is blocked on public testnets to prevent initialize() front-running." >&2
    exit 1
  fi
  if [[ ! -f "$INITCODE_HEX_FILE" ]]; then
    echo "[deploy] ERROR: Missing precompiled $INITCODE_HEX_FILE" >&2
    exit 1
  fi

  local initcode arb_wasm_code act_gas_raw act_gas_exceeds
  initcode="$(tr -d '[:space:]' < "$INITCODE_HEX_FILE")"
  arb_wasm_code="$(cast code 0x0000000000000000000000000000000000000071 --rpc-url "$RPC_URL")"
  if [[ "$arb_wasm_code" == "0x" ]]; then
    act_gas_raw="18446744073709551615"
    act_gas_exceeds="1"
  else
    act_gas_raw="$(cast call 0x0000000000000000000000000000000000000071 "activationGas()(uint64)" --rpc-url "$RPC_URL" | awk '{print $1}')"
    act_gas_exceeds="$(python3 -c 'import sys; s=sys.argv[1].strip(); assert s, "empty activationGas"; print("1" if int(s, 0) >= 32_000_000 else "0")' "$act_gas_raw")"
  fi

  if [[ "$act_gas_exceeds" == "1" ]]; then
    echo "[deploy] NOTICE: ArbWasm(0x71).activationGas()=$act_gas_raw (>=32M block cap; Arbitrum Security Council WASM activation pause active)." >&2
    write_checkpoint "stylusEngineAddress" "__NULL__"
    local raw_wasm_addr
    raw_wasm_addr="$(read_checkpoint "stylusWasmBytecodeAddress")"
    if is_deployed "$raw_wasm_addr"; then
      echo "[deploy] Reusing checkpointed raw Stylus WASM bytecode contract = $raw_wasm_addr" >&2
    else
      local raw_tx
      raw_tx="$(cast send --rpc-url "$RPC_URL" --json --create "$initcode")"
      raw_wasm_addr="$(printf '%s' "$raw_tx" | python3 -c "import json,sys; print(json.load(sys.stdin)['contractAddress'])")"
      write_checkpoint "stylusWasmBytecodeAddress" "$raw_wasm_addr"
      echo "[deploy] Deployed raw 0xEFF00000 Stylus WASM bytecode (24,522 B) at $raw_wasm_addr (awaiting ArbWasm activation unpause)" >&2
    fi
    write_checkpoint "stylusActivationStatus" "paused_arbwasm_activation_gas_u64_max"
    if [[ "$require_stylus" == "1" ]] && ! is_deployed "$raw_wasm_addr"; then
      echo "[deploy] ERROR: REQUIRE_STYLUS=1 and raw Stylus WASM contract deployment failed." >&2
      exit 1
    fi
    printf '%s\n' ""
    return 0
  fi

  local salt topic0 tx_json
  salt="0x$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  topic0="$(cast keccak 'EngineAtomicallyDeployed(address,address,bytes32,bool,bool)')"
  echo "[deploy] Deploying + activating Stylus engine atomically via StylusAtomicFactory ($factory_addr)..." >&2
  tx_json="$(cast send "$factory_addr" "deployAndInitialize(bytes,bytes32,address,bool)" "$initcode" "$salt" "$deployer_addr" false --value 0.002ether --rpc-url "$RPC_URL" --json)"
  stylus_engine="$(TX_JSON_ENV="$tx_json" python3 - "$topic0" <<'PYEOF'
import json, os, sys
topic0 = sys.argv[1].lower()
d = json.loads(os.environ["TX_JSON_ENV"])
for log in d.get("logs", []):
    topics = log.get("topics", [])
    if topics and topics[0].lower() == topic0 and len(topics) >= 2:
        print("0x" + topics[1][-40:])
        raise SystemExit(0)
raise SystemExit("EngineAtomicallyDeployed event not found in receipt logs")
PYEOF
)"
  write_checkpoint "stylusEngineAddress" "$stylus_engine"
  write_checkpoint "stylusWasmBytecodeAddress" "$stylus_engine"
  write_checkpoint "stylusActivationStatus" "active"
  echo "[deploy] Atomically deployed & initialized stylusEngineAddress = $stylus_engine" >&2
  if [[ "$require_stylus" == "1" ]] && ! is_deployed "$stylus_engine"; then
    echo "[deploy] ERROR: REQUIRE_STYLUS=1 but stylusEngineAddress is not deployed." >&2
    exit 1
  fi
  printf '%s\n' "$stylus_engine"
}

configure_engine_assets_and_risk() {
  local eng="$1"
  local tok0="$2"
  local tok1="$3"
  local tok2="$4"
  local tok3="$5"
  is_deployed "$eng" || return 0

  local count staleness
  count="$(cast call "$eng" "assetCount()(uint8)" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}' || echo 0)"
  if [[ "${count:-0}" -lt 4 ]]; then
    echo "[deploy] Configuring 4 institutional assets on $eng..." >&2
    cast send "$eng" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 0 "$tok0" 6 1000000000000000000 0 500 250 --rpc-url "$RPC_URL" >/dev/null
    cast send "$eng" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 1 "$tok1" 18 2850000000000000000000 1000 1000 500 --rpc-url "$RPC_URL" >/dev/null
    cast send "$eng" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 2 "$tok2" 18 1100000000000000000 2000 1500 750 --rpc-url "$RPC_URL" >/dev/null
    cast send "$eng" "configureAsset(uint8,address,uint8,uint256,uint16,uint16,uint16)" 3 "$tok3" 18 140000000000000000000 1500 1200 600 --rpc-url "$RPC_URL" >/dev/null
  fi
  staleness="$(cast call "$eng" "maxPriceStaleness()(uint64)" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}' || echo 0)"
  if [[ "${staleness:-0}" -lt 86400 ]]; then
    echo "[deploy] Setting testnet oracle staleness window (365d, +-20% band, permissionless) on $eng..." >&2
    cast send "$eng" "setRiskWindows(uint64,uint16,bool)" 31536000 2000 true --rpc-url "$RPC_URL" >/dev/null
  fi
}

prepare_chain_context() {
  local net_label="$1"
  setup_ephemeral_keystore
  ACTUAL_CHAIN="$(cast chain-id --rpc-url "$RPC_URL" | awk '{print $1}')"
  if [[ "$ACTUAL_CHAIN" != "$CHAIN_ID_EXPECTED" ]]; then
    echo "[deploy] ERROR: Expected chain ID $CHAIN_ID_EXPECTED, got $ACTUAL_CHAIN" >&2
    exit 1
  fi
  DEPLOYER_ADDR="$(cast wallet address)"
  OUT_JSON="$ROOT_DIR/deployments/$DEPLOY_OUT_NAME"
  WEB_JSON="$ROOT_DIR/web/deployments/$DEPLOY_OUT_NAME"
  COMPILED_JSON="$ROOT_DIR/artifacts/contracts-compiled.json"
  INITCODE_HEX_FILE="$ROOT_DIR/artifacts/clearing_stylus.initcode.hex"
  echo "[deploy] Network=$net_label (chainId=$ACTUAL_CHAIN) deployer=$DEPLOYER_ADDR"
}

finalize_chain_deployment() {
  local net_label="$1"
  local tok0="$2"
  local tok1="$3"
  local tok2="$4"
  local tok3="$5"
  local sol_engine="$6"
  local factory_addr="$7"

  local stylus_engine raw_wasm_note
  stylus_engine="$(deploy_or_stage_stylus_engine "$factory_addr" "$DEPLOYER_ADDR" "$REQUIRE_STYLUS" "$USE_ATOMIC_FACTORY")"
  for eng in "$sol_engine" "$stylus_engine"; do
    [[ -n "$eng" ]] || continue
    configure_engine_assets_and_risk "$eng" "$tok0" "$tok1" "$tok2" "$tok3"
  done
  write_checkpoint "demoTraderA" "$DEPLOYER_ADDR"
  raw_wasm_note="$(read_checkpoint "stylusWasmBytecodeAddress")"
  echo "[deploy] DONE ($net_label): Solidity=$sol_engine | StylusActive=${stylus_engine:-paused} | StylusWasmBytecode=${raw_wasm_note:-n/a}"
}
