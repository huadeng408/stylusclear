#!/usr/bin/env bash
set -euo pipefail

# StylusClear v1.2.0 Idempotent Atomic Deployment Script (robinhood-testnet)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=scripts/deploy-common.sh
source "$ROOT_DIR/scripts/deploy-common.sh"

RPC_URL="${ROBINHOOD_RPC_URL:-${SEPOLIA_RPC_URL:-https://rpc.testnet.chain.robinhood.com}}"
CHAIN_ID_EXPECTED="${CHAIN_ID_EXPECTED:-46630}"
DEPLOY_OUT_NAME="${DEPLOY_OUT_NAME:-robinhood-testnet.json}"
REQUIRE_STYLUS="${REQUIRE_STYLUS:-1}"
USE_ATOMIC_FACTORY="${USE_ATOMIC_FACTORY:-1}"

prepare_chain_context "robinhood-testnet"

TOK0="$(ensure_contract "assets.usdgMock6" "MockERC20" "constructor(string,string,uint8)" "USDG" "USDG" 6)"
TOK1="$(ensure_contract "assets.wethMock18" "MockERC20" "constructor(string,string,uint8)" "Wrapped Ether" "WETH" 18)"
TOK2="$(ensure_contract "assets.arbMock18" "MockERC20" "constructor(string,string,uint8)" "Arbitrum" "ARB" 18)"
TOK3="$(ensure_contract "assets.nvdaxMock18" "MockERC20" "constructor(string,string,uint8)" "NVIDIA RWA" "NVDAx" 18)"
SOL_ENGINE="$(ensure_contract "solidityBenchmarkAddress" "SolidityClearingBenchmark" "constructor(address,bool)" "$DEPLOYER_ADDR" false)"
FACTORY_ADDR="$(ensure_contract "atomicFactoryContract" "StylusAtomicFactory" "")"

finalize_chain_deployment "robinhood-testnet" "$TOK0" "$TOK1" "$TOK2" "$TOK3" "$SOL_ENGINE" "$FACTORY_ADDR"
