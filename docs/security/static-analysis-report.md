# StylusClear v0.8.0 Static Security Analysis Report

* **Analyzers Executed**: Foundry `forge lint` (`forge 1.9.0`, `solc 0.8.38`, `via_ir = true`), `cargo clippy --all-targets -- -D warnings` (`rustc 1.100.0`), Binaryen `wasm-opt --mvp-features` (`version 133`), and Z3 SMT (`6/6 PROVED_UNSAT`) + Hypothesis (`100/100` matched-auction differential fuzz cases + `clearing-cli` cross-check).
* **Legacy Slither Compatibility Note**: Offline `slither-analyzer 0.5.2` invokes deprecated `solc --ast-json` (removed in `solc 0.8.x`); full Solidity AST & security diagnostics were therefore executed via `forge lint` (`solc 0.8.38`) and audited item-by-item below.

## Findings & Security Triage

| Contract | Diagnostic Category | Verdict | Rationale |
| :--- | :--- | :---: | :--- |
| `StylusAtomicFactory.sol` | `reentrancy-events` (line 81) | **Benign / Safe** | Event emitted after atomic `CREATE2` + `ArbWasm(0x71).activateProgram` + `initialize` + excess ETH refund; no persistent state modified after external call. |
| `SolidityClearingBenchmark.sol` | `reentrancy-no-eth` (line 293 `_safeTransfer*`) | **Mitigated** | All external entrypoints and core `view` getters (`getAccountBalance`, `getVaultPhysicalRaw`) are guarded by `checkUnlocked` (`_unlocked` reentrancy mutex). |
| `SolidityClearingBenchmark.sol` | `ecrecover` malleability (line 728) | **Mitigated** | Explicit `uint256(s) > SECP256K1_HALF_N` (`0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0`) and `v != 27 && v != 28` checks precede `ecrecover` (`ClearingCore` parity verified by unit test). |
| `SolidityClearingBenchmark.sol` | `divide-before-multiply` (lines 531, 1145-1344) | **Intentional** | Deliberate floor quantization to raw token quantum (`rawOut * factor`) and lot/tick grid (`(x / step) * step`) proven safe by Z3 T2/T3/T6. |
| `SolidityClearingBenchmark.sol` | `block-timestamp` (lines 126, 287) | **Intentional** | Oracle staleness window (`DEFAULT_MAX_PRICE_STALENESS = 3600s`) and `uint64` timestamp bounds check. |
| `FullMath512.sol` | `unsafe-typecast` (lines 31-32) | **Mitigated** | Explicit `if (x > uint256(type(int256).max)) revert MathOverflow()` immediately precedes `int256(x)`. |
| `clearing-stylus` / `clearing-core` | `cargo clippy -- -D warnings` | **0 Warnings** | Strict `#![forbid(unsafe_code)]` on host, `#![deny(unsafe_code)]` on WASM, `storage_flush_cache(false)` enforced prior to all `call_contract` / `static_call_contract` calls. |
