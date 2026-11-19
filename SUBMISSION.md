# StylusClear (`v0.7.0`) — Competition & Ecosystem Submission Dossier

## Target Tracks & Ecosystem Alignment
1. **[Arbitrum Mentorship Program Cohort 2](https://blog.arbitrum.foundation/arbitrum-mentorship-program-cohort-2-applications-now-open/)** ([Builder's Block #029](https://blog.arbitrum.foundation/builders-block-029-pitch-to-50-investors-through-the-mentorship-program-compete-for-100k/) — `$100,000` prize pool + 50+ investor Demo Day, application deadline `2026-12-06`, co-hosted with Robinhood Chain).
2. **[Arbitrum Open House São Paulo: Online Buildathon](https://www.hackquest.io/zh-cn/hackathons/Arbitrum-Open-House-Sao-Paulo-Online-Buildathon)** ([Arbitrum Open House Portal](https://openhouse.arbitrum.io/) / [EarnKit Program Listing](https://earnkit.com/programs/arbitrum-open-house-sao-paulo) — `$115,000 USDC/USDG` pool, including dedicated top-tier placement consideration for projects deployed on [Robinhood Chain Testnet (`46630`)](https://docs.robinhood.com/chain/connecting/)).

## Executive Summary
**StylusClear** is an institutional-grade multilateral obligation cycle compression and 512-bit Uniform Clearing Price Batch Auction (`UCPBA`) clearing house written in `no_std` Rust for [Arbitrum Stylus](https://docs.arbitrum.io/stylus/concepts/webassembly). It solves sequential collateral lockups across `USDC`/`USDG` ([Arbitrum Stablecoin Growth Program](https://blog.arbitrum.io/stablecoin-growth-program/)), `WETH`, `ARB`, and tokenized equities (`NVDAx`) by compressing directed payable cycles via an `O(V²)` 2-Origin BFS algorithm before clearing net residual liquidity in a single uniform-price call auction.

## Key Technical Differentiators (`v0.7.0`)
* **AIP-31605 Reproducible WASM 1.0 MVP (`24,411 B` Brotli-q11)**: Built strictly with official Binaryen `wasm-opt` lowering passes (`0` floating-point ops, `0` post-MVP ops, `0` custom section mutations), fitting comfortably inside both the legacy `24,576 B` [Stylus VM cap](https://docs.arbitrum.io/stylus/concepts/vm-differences) and [`ArbOS 61`](https://docs.arbitrum.io/run-a-node/arbos-releases/arbos61)'s `96 KB` cap, paired with `StylusAtomicFactory.sol` for front-run-proof atomic initialization.
* **11.9x Stress-Tier Gas Advantage (`-91.6%` Gas) Under Cold Storage**: On a 44-desk, 88-obligation, 7-cycle, 88-intent stress batch under EIP-2929 `vm.cool()` cold storage, Solidity consumes `18,287,878` gas (within Arbitrum's `32,000,000` single-block limit in [Chain Params](https://docs.arbitrum.io/arbitrum-essentials/reference/chain-params)) whereas StylusClear's WASM engine executes `107,687,616` `wasmi` fuel instructions (`1,533,158` estimated total gas — **`11.93x` cheaper**).
* **6 Z3 SMT Formal Proofs + 6-Endpoint Differential Parity**: Every invariant—adaptive zero-deadlock `USDC/USDG` liquidation (`min(mm_bps / 2, 250)`), floor proportional collateral cap, 512-bit per-lot Individual Rationality, double-entry conservation, physical ERC-20 vault solvency, and sub-quantum debt closure—is proved `UNSAT` in `tools/formal/prove_invariants_z3.py` and fuzz-tested across Rust, Stylus WASM, Solidity, Python, CLI, and the Web Workbench.
* **Dual-Chain Arbitrum Sepolia (`421614`) + Robinhood Chain Testnet (`46630`) Support**: Turnkey deployment scripts (`deploy-sepolia.sh`, `deploy-robinhood-testnet.sh`) and keyless browser `eth_call` simulation across all 4 asset slots (`USDC/USDG`, `WETH`, `ARB`, `NVDAx`).

## Judge 15-Second Verification
```bash
bash scripts/verify-judge-60s.sh
```
