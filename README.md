# StylusClear (`v0.9.0`)

**Solverless Multilateral Obligation Cycle Compression, 512-Bit Uniform Clearing Price Batch Auction (UCPBA) & Cross-Margin Risk Engine in Arbitrum Stylus (Rust WASM 1.0 MVP)**

[![WASM Brotli-q11](https://img.shields.io/badge/Stylus_WASM_Brotli--q11-24527_B_%28%3C24KB%29-00d4ff)](#empirical-benchmarks-cold-evm-vs-stylus-wasm)
[![Z3 Formal Proofs](https://img.shields.io/badge/Z3_SMT_Theorems-6%2F6_PROVED_UNSAT-18e299)](#formal-verification--differential-testing)
[![Chains](https://img.shields.io/badge/Chains-Arbitrum_Sepolia_421614_%7C_Robinhood_Testnet_46630-9d7bff)](#dual-chain-deployment-arbitrum-sepolia--robinhood-chain-testnet)

![StylusClear Institutional Mesh Workbench](docs/assets/workbench-institutional-mesh.png)

## Why StylusClear?
Institutional trading desks settling `USDC`, `USDG`, `WETH`, `ARB`, and tokenized equities (`NVDAx`) on [Arbitrum](https://docs.arbitrum.io/stylus/gentle-introduction) and [Robinhood Chain Testnet (`46630`)](https://docs.robinhood.com/chain/connecting/) face severe capital lockups when bilateral payables settle sequentially, and catastrophic margin-rounding risks (exemplified by recent DeFi margin exploits covered on [CryptoTicker](https://cryptoticker.io/en/crypto-hack-news/)).

**StylusClear `v0.9.0`** executes two compute-intensive institutional primitives atomically inside a **`24,527`-byte** Brotli-compressed Rust WASM contract—with **zero external solver trust** and **100% bit-exact parity** against a Solidity `via_ir` reference twin:
1. **Canonical `O(V²)` 2-Origin BFS Multilateral Cycle Compression**: Ranks participants deterministically by address, prioritizes multilateral (`>=3`-hop) payable cycles over greedy 2-cycles in strict polynomial time, and cancels circular debt without touching collateral (`92.05%` liquidity savings on the standard 4-desk ring).
2. **512-Bit Uniform Clearing Price Batch Auction (UCPBA)**: Clears multi-party `Buy`/`Sell` intents at a single equilibrium price within a `±20%` reference oracle band, guaranteeing exact 512-bit per-lot Individual Rationality (`ceil` buyer debit, `floor` seller credit, non-negative rounding dust swept to `feeVault`).
3. **Adaptive Floor-Capped Portfolio Margin & Liquidation**: Enforces cross-asset haircutted collateral (`USDC/USDG`, `WETH`, `ARB`, `NVDAx`), post-batch Initial Margin / Health Monotonicity guards, physical ERC-20 vault solvency on spot withdrawals, sub-quantum dust/debt closure (`repaySubQuantumDebt`), and deadlock-free underwater liquidation (`bonus = min(mm_bps / 2, 250)`).

![StylusClear Fail-Closed Guard](docs/assets/workbench-fail-closed-guard.png)

## Empirical Benchmarks (Cold EVM `vm.cool()` vs Stylus WASM)
Measured with Foundry (`solc 0.8.38`, `via_ir = true`, `optimizer_runs = 200`, EIP-2929 cold storage via `vm.cool()`) vs. our offline analytical ArbOS Stylus cost model anchored to host-verified Rust `clearing-cli` replay (`scripts/measure-wasm-benchmarks.py`, including all 8 config cold SLOADs, all `get_partial_fill` cold SLOADs, conservative 5,000-gas SSTOREs, `ecrecover`, `native_keccak256`, and `memory_grow`; shared L2 calldata gas excluded identically from both sides' execution frames and disclosed in JSON) per [Arbitrum Stylus Gas & Ink Metering](https://docs.arbitrum.io/stylus/concepts/gas-metering), [HostIO Pricing](https://docs.arbitrum.io/stylus/reference/opcode-hostio-pricing), and the `32,000,000` single-block gas cap in [Arbitrum Chain Params](https://docs.arbitrum.io/arbitrum-essentials/reference/chain-params):

| Tier | Desks / Obs / Intents | Cycles Netted | Solidity Cold EVM Gas (`vm.cool()`, runs=200) | Analytical WASM Ops (Host Replay) | Stylus Total Gas Est. (Complete HostIO) | Gas Saved (`EVM / Stylus`) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| `Small` | 4 / 5 / 4 | 2 | `459,169` | `5,406,000` | `215,873` | **-53.0% (`2.13x`)** |
| `Medium` | 12 / 20 / 24 | 9 | `2,416,348` | `23,486,000` | `711,591` | **-70.6% (`3.40x`)** |
| `Large` | 32 / 64 / 64 | 33 | `10,574,713` | `87,682,000` | `1,908,829` | **-81.9% (`5.54x`)** |
| `Stress` | 44 / 88 / 88 | 45 | `18,284,070` | `136,990,000` | `2,617,806` | **-85.7% (`6.98x`)** |

* **Zero-Patch Reproducible WASM 1.0 MVP**: `65,341 B` raw / **`24,527 B` Brotli-q11** (`24,531 B` incl. 4 B Stylus prefix — `45 B` below the `24,576 B` [Stylus VM limit](https://docs.arbitrum.io/stylus/concepts/vm-differences) and `73,773 B` below [`ArbOS 61 ("Elara")`](https://docs.arbitrum.io/run-a-node/arbos-releases/arbos61)'s `96 KB` limit; local `v0.9.0` rebuild via `scripts/check.sh` yields `65,402 B` raw / `24,454 B` Brotli-q11, `118 B` below the 24 KiB cap), compiled using official Binaryen `wasm-opt` passes with **zero custom binary section mutation** (`AIP-31605` compliant per [[Constitutional] AIP: Stylus Activation Contract](https://forum.arbitrum.foundation/t/constitutional-aip-stylus-activation-contract/31605)).

## Formal Verification & Differential Testing
* **6 Z3 SMT Theorems (`tools/formal/prove_invariants_z3.py`)**: Machine-checked `PROVED_UNSAT` proofs for (T1) Zero-Deadlock `USDC/USDG` Adaptive Bonus Liquidation, (T2) Floor Proportional Cap No-Overcharge, (T3) 512-Bit UCPBA Per-Lot Individual Rationality, (T4) Double-Entry Conservation with Dust, (T5) Physical Vault Solvency, and (T6) Sub-Quantum Debt Single-Unit Closure.
* **Six-Endpoint Differential Parity**: Identical state transitions and 19-error fail-closed taxonomy verified across `crates/clearing-core`, `crates/clearing-stylus`, `contracts/src/SolidityClearingBenchmark.sol` (`15/15` Foundry tests incl. `2 x 256` fuzz runs), `tools/ref_sim/engine.py` (Hypothesis fuzzing), `clearing-cli`, and `web/engine-ui.mjs`.

## Quickstart (`< 20s` Judge Verification)
```bash
# Run full 5-stage judge audit (archcheck + WASM MVP validation + Cargo + Foundry + Z3 + Seam S1-S4)
bash scripts/verify-judge-60s.sh

# Launch interactive dual-chain workbench on http://127.0.0.1:8080
python3 -m http.server 8080 --directory web
```

## Dual-Chain Deployment (Arbitrum Sepolia & Robinhood Chain Testnet)
```bash
export PRIVATE_KEY="0x..."
# 1. Arbitrum Sepolia (Chain ID 421614)
bash scripts/deploy-sepolia.sh && bash scripts/demo-sepolia-live.sh sepolia

# 2. Robinhood Chain Testnet (Chain ID 46630 — USDG + NVDAx RWA slot)
bash scripts/deploy-robinhood-testnet.sh && bash scripts/demo-sepolia-live.sh robinhood

# 3. Mux pre-rendered 1080p60 video segments + -14 LUFS narration (+ optional 32s live explorer clip)
bash scripts/build-final-video.sh [optional_live_32s.mp4] docs/assets/demo-final.mp4
```

## Repository Structure
* `crates/clearing-core` — `no_std` deterministic Rust kernel (`O(V²)` 2-Origin BFS netting, 512-bit UCPBA, portfolio margin, liquidation).
* `crates/clearing-stylus` — Zero-patch Arbitrum Stylus WASM contract (`29` ABI methods, host-native `keccak256`, `StylusAtomicFactory` compatible).
* `contracts/src/` — `ISettlementEngine.sol`, `SolidityClearingBenchmark.sol`, `StylusAtomicFactory.sol`, `FullMath512.sol`, `MockERC20.sol`.
* `tools/formal/prove_invariants_z3.py` & `tools/ref_sim/` — Z3 SMT formal prover, Hypothesis fuzzer, and Python reference verifier.
* `web/` — Zero-key dual-chain (`421614` & `46630`) interactive Workbench (`<5ms` 64-desk mesh, 4-asset ledger, liquidation simulator).
* `docs/assets/video_kit/` — Pre-rendered `1080p60` MP4 segments, `-14 LUFS` English narration + CC0 BGM master track, and `.srt`/`.ass` subtitles.
