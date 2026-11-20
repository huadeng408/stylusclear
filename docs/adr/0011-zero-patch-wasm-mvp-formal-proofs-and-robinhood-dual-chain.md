# ADR-0011: Zero-Patch WASM 1.0 MVP Pipeline, Z3 Formal Proofs, O(V²) 2-Origin BFS, and Robinhood Chain (46630) Dual-Chain Support

* **Status**: Accepted (`v1.2.0`)
* **Date**: 2026-11-19
* **Supersedes / Extends**: ADR-0009, ADR-0010

## Context
A five-track red-team audit of `v0.6.0` identified key hardening opportunities for institutional production readiness and [Arbitrum Open House São Paulo](https://www.hackquest.io/zh-cn/hackathons/Arbitrum-Open-House-Sao-Paulo-Online-Buildathon) / [Arbitrum Mentorship Program Cohort 2](https://blog.arbitrum.foundation/arbitrum-mentorship-program-cohort-2-applications-now-open/):
1. Custom WASM binary byte-splicing breaks reproducible codehash verification under [[Constitutional] AIP: Stylus Activation Contract (`AIP-31605`)](https://forum.arbitrum.foundation/t/constitutional-aip-stylus-activation-contract/31605), while monkey-patching `stylus-sdk` breaks clean offline/Docker `--locked` builds.
2. Fixed `250 bps` liquidation bonus caused `HealthMonotonicityViolated` deadlocks when seizing zero-haircut stablecoins (`USDC`/`USDG`) against `mm_bps = 250` debt, and nested `ceil` back-calculation risked 1-wei rounding deadlocks.
3. Recursive DFS cycle search degraded on dense 32–44-node chord graphs, and greedy 2-cycle selection left multilateral `>=3`-cycles uncompressed.
4. Robinhood Chain Testnet (`46630`, [Connecting to Robinhood Chain](https://docs.robinhood.com/chain/connecting/)) reserves top-tier ecosystem focus for tokenized equities (`NVDAx`) paired with `USDG`.

## Decisions
1. **Zero-Patch Reproducible WASM 1.0 MVP (`24,518 B` Brotli-q11)**: Replace `stylus-sdk` macros with a clean, self-contained `mini-alloc` + `alloy-primitives` Stylus ABI dispatcher and lower bulk-memory / sign-ext instructions exclusively via official Binaryen `wasm-opt` passes (`--llvm-memory-copy-fill-lowering --signext-lowering -Oz`), verified by `wasm-opt --mvp-features` (`0` post-MVP opcodes, `121 B` below the `24,576 B` legacy limit and `73.8 KB` below [`ArbOS 61`](https://docs.arbitrum.io/run-a-node/arbos-releases/arbos61)'s `96 KB` cap).
2. **Atomic Initialization (`StylusAtomicFactory.sol`) & Two-Step Admin**: Prevent front-running between WASM activation and `initialize(admin, false)` via `StylusAtomicFactory` and enforce `transferAdmin` / `acceptAdmin`.
3. **Adaptive Floor-Capped Liquidation & 6 Z3 `UNSAT` Proofs**: Set `bonus_bps = min(mm_bps / 2, 250)` (`125 bps` for `USDC/USDG`, `250 bps` for `WETH/ARB/NVDAx`) and compute `Proportional Cap` via two-step `floor` division with spot inventory verification, formally proved deadlock-free and overcharge-free in `tools/formal/prove_invariants_z3.py`.
4. **Exact `O(V^2)` 2-Origin BFS Cycle Compression & Selective Oracle Freshness**: Prioritize multilateral (`>=3`-hop) rings over bilateral 2-cycles in polynomial time without recursion, and validate oracle staleness strictly across active batch assets (`active_mask`).
5. **Dual-Chain (`421614` + `46630`) & Cold-Storage Empirical Benchmarks**: Ship complete deployment configs and scripts for both Arbitrum Sepolia (`421614`) and Robinhood Chain Testnet (`46630`), and calibrate `measured-gas-artifacts.json` using `forge test -vvvv` with `vm.cool()` (`Stress = 16,645,399 < 32,000,000`, `SolidityClearingBenchmark` runtime `24,518 B < 24,576 B` EIP-170 [Arbitrum Chain Params](https://docs.arbitrum.io/arbitrum-essentials/reference/chain-params)) paired with host-verified Rust `clearing-cli` replay and an analytical EIP-2929 HostIO model.
