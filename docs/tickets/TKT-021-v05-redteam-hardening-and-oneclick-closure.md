# TKT-021: v0.5 Red-Team Security Hardening, WASM 1.0 Gate, Multi-Chord Benchmarks & One-Click WSL2 Closure

- **Status**: Completed (`v0.5.0`)
- **Blocked by**: `TKT-018`, `TKT-019`, `TKT-020`
- **Testing Seam**: `Seam S1`, `Seam S2`, `Seam S3`, `Seam S4`

## Objective

Remediate 100% of findings from the 4-subagent red-team audit in the cloud workspace so local WSL2 migration is reduced to a single idempotent command (`scripts/wsl2-oneclick-finish.sh`).

## Acceptance Criteria

1. **Cryptographic & Auction Invariants (`Seam S1`)**: Fix `SECP256K1_HALF_N = N >> 1` and `r < N`; reject same-trader opposite-side wash intents and zero-settlement batches; preserve unmatched EIP-712 nonces; enforce constant `10^9` Wei lot step and in-band candidate filtering with 4-sig-fig `ref_tick`.
2. **Lifecycle & Cross-VM Hardening (`Seam S2`)**: Add `liquidate`, `sweepDustToFeeVault`, `invalidateNonces`, `revokeObligation`, and `setApprovedSolver` across `ISettlementEngine.sol`, `SolidityClearingBenchmark.sol`, and `StylusClearingEngine`; enforce immutable `token`/`decimals`, `Host::msg_reentrant()`, `SafeERC20` optional-bool return check, Solidity candidate deduplication, and multi-chord cycle benchmarks (`2 / 9 / 33 / 62` cycles).
3. **Bundled `viem` Workbench & Submission Package (`Seam S3`)**: Bundle `web/rpc-client.ts` + local `viem` into `web/dist/rpc-client.mjs` (`esbuild`); add SVG cycle topology graph, `4/12/32/64` scale slider, Robinhood Chain (`46630`) + USDG scenario, counterparty wallet re-signing, transition-free Retina screenshots, `SUBMISSION.md`, and `docs/DEMO_VIDEO_SCRIPT.md`.
4. **WASM 1.0 & One-Click Local Gate (`Seam S4`)**: Add `.cargo/config.toml` (`-reference-types,-simd128`), `.gitattributes` (`eol=lf`), `Dockerfile.stylus-reproducible`, DrvFS-safe `scripts/check.sh`, CREATE2 salt-resilient `scripts/deploy-sepolia.sh`, domain-hashed idempotent `scripts/demo-sepolia-live.sh`, and `scripts/wsl2-oneclick-finish.sh`.
