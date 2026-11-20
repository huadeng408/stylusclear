# StylusClear v1.2.0 — Hackathon Submission

* **Track**: Arbitrum Stylus / Institutional DeFi & Robinhood Chain (`46630` USDG + `NVDAx` RWA Clearing) — [Arbitrum Open House / Buildathon](https://arbitrum.foundation/)
* **Repository Version**: `v1.2.0` (Dual-VM `no_std` Rust Stylus WASM 1.0 MVP + Bit-Exact Solidity Reference)
* **Deployment Status**: `Pending Local Broadcast (Zero-Mock)` — `deployments/arbitrum-sepolia.json` (`421614`) and `deployments/robinhood-testnet.json` (`46630`) are auto-populated with verified contract addresses and transaction hashes via `2-DEPLOY-AND-PUSH.cmd` / `scripts/wsl2-oneclick-finish.ps1`.

## Problem Statement

Institutional OTC desks, prime brokers, and tokenized-equity venues (`NVDAx`, `USDG`, `WETH`, `ARB`) face severe capital fragmentation and on-chain compute bottlenecks when settling multilateral obligations alongside batch auctions. Executing `O(V²)` graph cycle compression, 512-bit Uniform Clearing Price Batch Auctions (UCPBA), and multi-asset margin invariants in pure Solidity EVM hits steep gas costs (`16.65M` gas at 44 desks / 88 intents under cold storage, even after compact bitmap optimization).

## Solution: StylusClear v1.2.0

StylusClear moves the compute-heavy clearing core into **Arbitrum Stylus (`no_std` Rust → WASM 1.0 MVP)** while maintaining 100% bit-exact parity (`37` ABI methods, `19` custom errors, identical read-only reentrancy guards, dust-collateral deadlock immunity, and 64-byte return-data bomb caps) with `SolidityClearingBenchmark.sol` (`24,514 B`):

* **Zero-Patch WASM 1.0 MVP**: `65,635 B` raw / **`24,518 B` Brotli-q11** (`24,522 B` incl. 4 B header — `54 B` below the `24,576 B` legacy cap, `73,782 B` below `ArbOS 61` `96 KB` cap; `0` float / `0` post-MVP opcodes).
* **Cold-Storage Gas Advantage (`optimizer_runs = 200`, `vm.cool()`, full `20k` cold nonce SSTORE + quadratic `memory_grow`)**: `1.70x` exec / `1.61x` e2e (Small, `-41.2%`), `2.94x` exec / `2.53x` e2e (Medium, `-66.0%`), `4.63x` exec / `3.85x` e2e (Large, `-78.4%`), and **`5.71x` exec / `4.69x` e2e (Stress: `2,917,316` vs `16,645,399` gas, `-82.5%`)** (`docs/benchmarks/gas-comparison-report.md`).
* **Formal Verification (`docs/security/z3-formal-proofs.json`)**: **6/6 non-trivial Z3 SMT theorems `PROVED_UNSAT`** (T1 full-domain `haircut_c in [0, 9999]` Adaptive Bonus Zero-Deadlock, T2 Proportional Cap Bound, T3 UCPBA IR & Unaligned `<1 wei` Dust Bound, T4 Full-Domain U512 FullMath Overflow & Carry Guard, T5 4-Step Multi-Decimal Vault Transition Solvency, T6 BitVec(256) Sub-Quantum Debt Exit) + **100/100 EIP-712 Hypothesis differential cases** verified bit-for-bit against the compiled Rust `clearing-cli` binary (`cli_replay_cross_checked: true`).
* **5-Stage Verification (`< 60s`)**: Run `bash scripts/verify-judge-60s.sh` to independently verify `archcheck --strict`, `wasm-opt --mvp-features`, Rust (`9/9`), Foundry (`18/18`, `2x256` fuzz), Z3 (`6/6`), Python Seam S1/S2/S4 (`10/10`), Node Seam S3 (`37-method ABI`, zero `node_modules`), and Headless Chromium 3-viewport E2E (`1440x980`, `768x1024`, `390x844`).
* **Demo Video Assembly**: Rendered locally after live testnet broadcast via `bash scripts/build-final-video.sh <live_clip.mp4>` (enforces `ffprobe` 1080p60 / 193.0s audio+subtitle sync gate; see [`docs/DEMO_VIDEO_SCRIPT.md`](docs/DEMO_VIDEO_SCRIPT.md) and never mix pre-v1.2.0 MP4s with v1.2.0 metrics).
