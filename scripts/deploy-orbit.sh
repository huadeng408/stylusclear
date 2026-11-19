#!/usr/bin/env bash
set -euo pipefail
export RPC_URL="${ORBIT_RPC_URL:-http://127.0.0.1:8547}"
export CHAIN_ID_EXPECTED="${ORBIT_CHAIN_ID:-412346}"
echo "[deploy-orbit] Delegating to Arbitrum Orbit / Stylus deployment flow on $RPC_URL (chainId=$CHAIN_ID_EXPECTED)"
exec bash "$(dirname "$0")/deploy-sepolia.sh"
