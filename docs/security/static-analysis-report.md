# StylusClear v1.1.0 Static Analysis & Formal Security Report

* **Automated Gates Verified (`v1.1.0`)**:
  * Rust: `cargo clippy --workspace --all-targets -- -D warnings` (`0` warnings), `cargo test --workspace` (`8/8` passed)
  * WASM 1.0 MVP: `wasm-opt --mvp-features` (`0` float / `0` SIMD / `0` bulk-memory / `0` post-MVP opcodes; `65,845 B` raw / `24,484 B` Brotli-q11, `SHA-256: eeb23f80174924ea880bebc7cd50bf35d04697be1e4ee3f6cc84d00e06b55277`)
  * Solidity: `forge test` (`17/17` passed incl. `2x256` differential fuzz runs & `testV10_FactoryArbWasmRefundSubQuantumRepayAndGuards`), `SolidityClearingBenchmark` `24,484 B` runtime (`optimizer_runs = 200`), `StylusAtomicFactory` `2,064 B` runtime
  * Formal SMT & Fuzz: `tools/formal/prove_invariants_z3.py --require-cli --examples 100` (**6/6 Z3 theorems `PROVED_UNSAT`** + **100/100 EIP-712 Hypothesis differential cases** verified bit-for-bit against compiled Rust `clearing-cli`, `cli_replay_cross_checked: true`)
  * Python & Shell & Frontend: `pytest -v` (`8/8`), `ruff check tools tests scripts` (`0` errors), `mypy tools` (`0` errors), `bash -n scripts/*.sh` (`0` errors), `node tests/test_seam_s3_workbench.mjs` (`37-method ABI`, real `0xcf36836c` calldata check)

## Triaged Solidity & Stylus Audit Notes (`v1.1.0`)

| Finding / Check | Location | Status | Disposition |
| :--- | :--- | :---: | :--- |
| `StylusAtomicFactory` CEI & `benchmarkSeedingEnabled()` | `contracts/src/StylusAtomicFactory.sol:88-100`, `crates/clearing-stylus/src/lib.rs:96,1866-1871` | **CLOSED** | `SEL_BENCHMARK_SEEDING` (`0xed80e033`) implemented in Stylus; `emit EngineAtomicallyDeployed` (`line 95`) precedes excess ETH refund (`lines 97-100`). |
| Same-block Mark Price 50% Circuit Breaker | `crates/clearing-stylus/src/lib.rs:713-721`, `contracts/src/SolidityClearingBenchmark.sol:339-349` | **CLOSED** | Both `updateMarkPrice` and `configureAsset` reject same-block price mutations (`ts <= priceUpdatedAt`). |
| Read-Only Reentrancy Parity | `contracts/src/SolidityClearingBenchmark.sol:176-285`, `crates/clearing-stylus/src/lib.rs:1736-1978` | **CLOSED** | All external view functions enforce `checkUnlocked` / `check_non_reentrant` identically across both VMs. |
| Non-Standard ERC-20 Return & `sweepFeeVault` Balance | `contracts/src/SolidityClearingBenchmark.sol:295-315,540-550`, `crates/clearing-stylus/src/lib.rs:1086-1096` | **CLOSED** | Low-level `staticcall` for `balanceOf`, `uint256(bytes32(ret)) == 1` return validation, and live `balanceOf >= rawOut` enforced on both VMs. |
| 18-Dec Sub-Lot Dust Liquidation Clearance | `crates/clearing-core/src/engine.rs:267-273`, `contracts/src/SolidityClearingBenchmark.sol:644-646`, `tools/ref_sim/engine.py:631-633` | **CLOSED** | Full-debt clearance (`repaidDebtWad == absDebt`) exempts `MIN_INTENT_AMOUNT_WAD` floor across all 3 implementations. |
