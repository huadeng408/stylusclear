# ADR-0007: Offline Toolchain Mounting, Sub-Unit Cross-Pair Tick Quantization, Debt-Gated Oracle Freshness & Four-Surface Workbench Parity

* **Status**: Accepted
* **Date**: 2026-11-17
* **Context**: Second-round award-readiness audit (`TKT-011`–`TKT-015`) identified six compiler, differential, risk, and frontend parity gaps between offline reference logic and live Rust `1.91.0` / Foundry `0.8.24` / Arbitrum Sepolia execution:
  1. `k256` required `alloc` (and `std` in native CLI/test targets) for `VerifyingKey::to_encoded_point`, and `clearing-stylus` needed an explicit `[[bin]]` gated behind `required-features = ["export-abi"]` so `cargo test --workspace` and `cargo clippy --all-targets` never link WASM `vm_hooks` on host targets.
  2. `Foundry` deprecated `--no-commit` on `forge install`, and `ClearingDifferential.t.sol` required `vm.parseUint(vm.parseJsonString(...))` plus `vm.etch` at the canonical `verifying_contract` address to validate raw `golden_batches.json` signatures without re-signing.
  3. Cross-asset markets whose exact `ref_price` is not divisible by `10^9` (such as `WETH/ARB`) fell back to whole-token (`10^18`) lot steps, zeroing out sub-unit institutional orders, while `withdraw()` allowed accounts carrying liabilities to withdraw collateral during an oracle blackout without checking `StaleMarkPrice`.
  4. `web/engine-ui.mjs` omitted Stage 2 intent authentication (`DIRECT` vs `EIP712`), causing preset scenarios to revert with `UnauthorizedCaller` on live nodes.

## Decision

1. **Rust `1.91.0` + `stylus-sdk 0.10.10` Workspace Isolation**:
   - Enable `features = ["ecdsa", "alloc"]` on workspace `k256`, add `features = ["std"]` in `clearing-cli` and `clearing-stylus` `[dev-dependencies]`, and gate `clearing-stylus` binary target `clearing-stylus-abi` behind `required-features = ["export-abi"]`.
2. **Zero-Submodule Offline Foundry & 512-Bit Deviation Band**:
   - Keep `contracts/` 100% self-contained without external git submodules, replace raw 256-bit `priceDiff * BPS_DENOM > refPrice * maxPriceDeviationBps` with 512-bit `FullMath512.mulDivCeil(priceDiff, BPS_DENOM, refPrice) > maxPriceDeviationBps`, and mount `SolidityClearingBenchmark` via `vm.etch` at `0x2222222222222222222222222222222222222222` to replay `golden_batches.json` directly.
3. **Debt-Gated `withdraw()` Oracle Freshness & `ref_tick` (`10^9` Wei) Quantization**:
   - In `withdraw()`, enforce `block_timestamp - price_updated_at <= max_price_staleness` across all configured assets **if and only if** `post_risk.total_liability_wad > 0`, preserving unconditional exit for debt-free depositors while blocking stale-price margin drain by leveraged shorts.
   - Quantize the reference price candidate into `ref_tick = (ref_price / 10^9) * 10^9` across Rust, Solidity, Python, and JS so non-USD cross pairs (`WETH/ARB`) clear at `10^-9` base-asset precision with zero buyer limit overshoot, while measuring `ref_dist` and the `±max_price_deviation_bps` band against exact `ref_price`.
4. **Cryptographic Four-Surface Parity & Real `viem` Workbench**:
   - Enforce real secp256k1 EIP-712 signature recovery and `DIRECT` caller checks in `web/engine-ui.mjs` Stage 1 & Stage 2, pre-sign non-caller preset intents with deterministic `chainId = 421614` keys, sync wallet `signer` into `accounts[0].address`, and verify bit-identical outcomes for all preset scenarios across JS, Python, and Rust.

## Consequences

- `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo build --release --target wasm32-unknown-unknown -p clearing-stylus`, `forge test --offline -vv`, and `node --test` share bit-identical behavior with zero silent fallbacks.
