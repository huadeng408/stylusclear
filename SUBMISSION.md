# StylusClear v1.1.0 — Hackathon Submission

* **Track**: Arbitrum Stylus / Institutional DeFi & Robinhood Chain (`46630` USDG + `NVDAx` RWA Clearing) — [Arbitrum Open House / Buildathon](https://arbitrum.foundation/)
* **Repository Version**: `v1.1.0` (Dual-VM `no_std` Rust Stylus WASM 1.0 MVP + Bit-Exact Solidity Reference)
* **Deployment Status**: `Pending Local Broadcast (Zero-Mock)` — `deployments/arbitrum-sepolia.json` (`421614`) and `deployments/robinhood-testnet.json` (`46630`) are auto-populated with verified contract addresses and transaction hashes via `scripts/wsl2-oneclick-finish.ps1`.

## Problem Statement

Institutional OTC desks, prime brokers, and tokenized-equity venues (`NVDAx`, `USDG`, `WETH`, `ARB`) face severe capital fragmentation and on-chain compute bottlenecks when settling multilateral obligations alongside batch auctions. Executing `O(V²)` graph cycle compression, 512-bit Uniform Clearing Price Batch Auctions (UCPBA), and multi-asset margin invariants in pure Solidity EVM hits steep gas costs (`18.30M` gas at 44 desks / 88 intents under cold storage).

## Solution: StylusClear v1.1.0

StylusClear moves the compute-heavy clearing core into **Arbitrum Stylus (`no_std` Rust → WASM 1.0 MVP)** while maintaining 100% bit-exact parity (`37` ABI methods, `19` custom errors, identical read-only reentrancy guards) with `SolidityClearingBenchmark.sol`:

* **Zero-Patch WASM 1.0 MVP**: `65,845 B` raw / **`24,484 B` Brotli-q11** (`24,488 B` incl. 4 B header — `71 B` below the `24,576 B` legacy cap, `73,799 B` below `ArbOS 61` `96 KB` cap; `0` float / `0` post-MVP opcodes).
* **Cold-Storage Gas Advantage (`optimizer_runs = 200`, `vm.cool()`)**: `2.26x` (Small, `-55.8%`), `3.93x` (Medium, `-74.6%`), `6.43x` (Large, `-84.4%`), and **`8.11x` (Stress: `2,256,292` vs `18,296,420` gas, `-87.7%`)** under complete EIP-2929 HostIO modeling (`docs/benchmarks/gas-comparison-report.md`).
* **Formal Verification (`docs/security/z3-formal-proofs.json`)**: **6/6 Z3 SMT theorems `PROVED_UNSAT`** (T1 `T1_U256_Adaptive_Bonus_Zero_Deadlock`, T2 `T2_Floor_Proportional_Cap_Bound`, T3 `T3_UCPBA_Individual_Rationality_And_Bounded_Dust`, T4 `T4_FullDomain_U512_FullMath_Overflow_And_Carry_Guard`, T5 `T5_U256_MultiDecimal_Vault_Solvency`, T6 `T6_BitVec256_SubQuantum_Debt_Exit_Guarantee`) + **100/100 EIP-712 Hypothesis differential cases** verified bit-for-bit against the compiled Rust `clearing-cli` binary (`cli_replay_cross_checked: true`).
* **5-Stage Verification (`< 20s`)**: Run `bash scripts/verify-judge-60s.sh` to independently verify `archcheck --strict`, `wasm-opt --mvp-features`, Rust (`8/8`), Foundry (`17/17`, `2x256` fuzz), Z3 (`6/6`), Python Seam S1/S2/S4 (`8/8`), and Node Seam S3 (`37-method ABI`, real `0xcf36836c` calldata decoding).
* **Demo Video**: [`docs/assets/demo-preview.mp4`](docs/assets/demo-preview.mp4) (`1920x1080 @ 60fps`, `193.0s`, burned-in ASS subtitles + `mov_text`, see [`docs/DEMO_VIDEO_SCRIPT.md`](docs/DEMO_VIDEO_SCRIPT.md)).
