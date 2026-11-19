# ADR-0009: Solver-Less Monotonic UCPBA, Permissionless Underwater Liquidation, Exact EIP-2 Half-Order & Sub-Quantum Dust Closure

- **Status**: Accepted (`v0.5.0`, updated by `ADR-0010` in `v0.6.0`)
- **Date**: 2026-11-18
- **Supersedes / Extends**: `ADR-0003`, `ADR-0006`, `ADR-0008`

## Context

A 4-agent red-team audit of `StylusClear v0.4.0` identified six subtle protocol, cryptographic, and cross-VM edge cases:
1. `SECP256K1_HALF_N` in `crates/clearing-core/src/auth.rs` was transcribed as `N - 2^255` (`0x7fff...fffe_baaedce6af48a03bbfd25e8cd0364141`) rather than `N >> 1` (`0x7fff...ffff_5d576e7357a4501ddfe92f46681b20a0`), rejecting half of valid low-`s` EIP-2 signatures in `s in (N - 2^255, N / 2]`.
2. Dynamic `lot_step_for_price(p) = lcm(10^9, 10^18 / gcd(p, 10^18))` made aggregate demand non-monotonic across candidate prices (allowing a 1-Gwei ask to shift clearing price by `+19.7%` when large bids rounded down to zero lots at `p + 1 wei`) and forced `rounding_dust_quote_wad == 0` identically.
3. Same-trader opposite-side intents (`BUY` + `SELL` on the same `(base, quote)` market) allowed zero-collateral wash volume to dominate UCPBA tie-breakers and dilute honest pro-rata fills.
4. Empty or zero-settlement batches incremented `currentEpoch` (expiring live `maxEpoch` intents) while unmatched intents permanently burned EIP-712 nonces.
5. Maintenance margin (`mm_bps` / `health_wad`) lacked an on-chain close-out mechanism (`liquidate`), `<18`-decimal ERC-20 tokens (`USDC` 6d) left sub-quantum WAD dust (`< 10^12` WAD) unwithdrawable, and `configureAsset` permitted mutating `decimals`/`token` on initialized assets.
6. Rust `1.82+` enables WASM `reference-types` (`0x6F`/`0x70`) by default on `wasm32-unknown-unknown` ([Rust Blog](https://blog.rust-lang.org/2024/09/24/webassembly-targets-change-in-default-target-features/)), which is rejected by [Arbitrum Stylus `ArbWasm` activation](https://docs.arbitrum.io/stylus/concepts/webassembly).

## Decision

1. **Exact EIP-2 `SECP256K1_HALF_N` & Upper Bound**: Fix `SECP256K1_HALF_N = N >> 1` and enforce `0 < r < SECP256K1_N` and `0 < s <= SECP256K1_HALF_N` across Rust, Solidity, Python, and TypeScript/ESM (`parseWalletSignatureHex` also enforces low-`s` on EIP-2098 compact signatures).
2. **Constant Monotonic Lot Step (`10^9` Wei) & 4-Sig-Fig `ref_tick`**: Fix UCPBA quantization step to `MIN_INTENT_AMOUNT_WAD = 10^9` across all prices (guaranteeing monotonic demand/supply and routing non-zero buyer-ceil minus seller-floor spread dust into `feeVault`), filter candidate prices strictly inside `[minBand, maxBand]` before auction evaluation (`LimitPriceViolated` if only out-of-band orders cross), deduplicate candidate prices in both Rust and Solidity, and preserve 4 significant digits in `quantize_reference_tick` (`<= 0.1%` truncation).
3. **Wash-Trade Prevention, Non-Empty Settlement & Selective Nonces**: Reject opposite-side intents from the same trader on the same market (`InvalidIntent`), reject batches where both `obligations` and `totalMatchedVolumeWad` are zero (`InvalidIntent`) after Stage 4 `I256` conservation checks, and consume EIP-712 intent nonces only when `filled_base_wad > 0`.
4. **Lifecycle Completeness (`liquidate`, `sweepDustToFeeVault`, `invalidateNonces`, `revokeObligation`, `setApprovedSolver`)**: Implement permissionless underwater close-out (`health_wad < 0`) capped by `min(mm_bps, 250 bps)` (`LIQUIDATION_BONUS_CAP_BPS = 250`, refined with proportional collateral-shortfall repayment scaling in `ADR-0010`) while preserving zero-sum conservation and liquidator IM; add `sweepDustToFeeVault(assetId)` to sweep sub-quantum WAD dust into `feeVault`; lock `token`/`decimals` once initialized (`InvalidAssetConfig`) with duplicate-token rejection; and enforce `Host::msg_reentrant()` ([Stylus Rust SDK Guide](https://docs.arbitrum.io/stylus/reference/rust-sdk-guide)).
5. **Strict WASM 1.0 Compilation & Scanner**: Pin `.cargo/config.toml` `rustflags = ["-C", "target-feature=-reference-types,-simd128,-multivalue"]` and extend `scripts/generate-benchmarks.py` to fail closed on any WASM `reference-types`, `0xFD` SIMD, `DataCount`, or float opcode.

## Consequences

- All six endpoints (`clearing-core`, `clearing-stylus`, `SolidityClearingBenchmark.sol`, `tools/ref_sim`, `web/rpc-client.ts`, `web/dist/rpc-client.mjs`) maintain 100% selector and behavioral parity (`Rules A1–A7`), verified across multi-chord cycle benchmarks (`2`, `9`, `33`, and `62` cycles eliminated).
