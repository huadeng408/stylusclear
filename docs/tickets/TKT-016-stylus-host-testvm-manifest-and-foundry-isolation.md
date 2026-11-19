# TKT-016: Fix Rust 1.91 / Stylus 0.10.10 Host & TestVM Signatures, Stylus.toml Manifest, Clippy Loops, and Foundry vm.etch Isolation

- **Status**: `completed`
- **Priority**: P0
- **Blocked by**: `TKT-011`, `TKT-012`
- **Testing Seam**: `Seam S2` (`crates/clearing-stylus`, `contracts/test/ClearingDifferential.t.sol`)

## Acceptance Criteria
1. Replace private `stylus_sdk::host::Host` with public `Host` from `stylus_sdk::prelude::*`, pass 4 arguments (`U256::ZERO` value) to `TestVM::mock_call`, remove test-mode fallback in `EvmPrecompileVerifier`, and add `[contract.deployments]` to `crates/clearing-stylus/Stylus.toml`.
2. Eliminate all `clippy::needless_range_loop` patterns across workspace crates and mark `FullMath512.sol` inline assembly blocks `assembly ("memory-safe")`.
3. Split `testGoldenVectors_LoadedFromJsonFile` into 4 isolated `testGolden01..04_*` functions in `ClearingDifferential.t.sol` so `vm.etch` storage never leaks across golden vectors.
