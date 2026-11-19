# TKT-026: StylusClear v0.7.0 Red-Team Closure, Z3 Formal Proofs, Dual-Chain (421614 & 46630) & Pre-Rendered 1080p60 Video Kit

* **Blocked by**: TKT-025
* **Testing Seam**: Seam S1, Seam S2, Seam S3, Seam S4
* **Status**: Completed (`v0.7.0`)

## Scope & Acceptance Criteria
1. Close all 36 red-team findings across Rust (`clearing-core`, `clearing-stylus`, `clearing-cli`), Solidity (`SolidityClearingBenchmark.sol`, `StylusAtomicFactory.sol`, `MockERC20.sol`), Python (`tools/ref_sim/engine.py`), and TypeScript/ESM (`web/rpc-client.ts`, `web/engine-ui.mjs`).
2. Prove 6 core invariants `UNSAT` via `z3-solver` (`tools/formal/prove_invariants_z3.py`) and run Hypothesis differential fuzzing.
3. Measure empirical WASM fuel via `wasmi` on `artifacts/clearing_stylus.wasm` (`24,411 B` Brotli-q11) alongside cold-storage Foundry `vm.cool()` EVM gas (`Stress < 32,000,000`).
4. Add Robinhood Chain Testnet (`46630`) deployment configs/scripts, render `2880x1840` 2x Retina workbench screenshots, and pre-render the `1080p60` demo video segments + `-14 LUFS` ducked English narration master track.
