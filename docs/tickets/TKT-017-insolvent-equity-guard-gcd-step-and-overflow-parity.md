# TKT-017: Enforce Insolvent Net-Equity Monotonicity (CRIT-01), GCD Lot-Step Quantization, and Five-Endpoint Overflow Parity

- **Status**: `completed`
- **Priority**: P0
- **Blocked by**: `TKT-016`
- **Testing Seam**: `Seam S1` & `Seam S2` (`clearing-core`, `clearing-stylus`, `SolidityClearingBenchmark.sol`, `tools/ref_sim`, `web/engine-ui.mjs`)

## Acceptance Criteria
1. Cap `haircut_bps < 10_000` (`InvalidHaircut`), compute `gross_collateral_wad` and `net_equity_wad`, and reject any batch touching an underwater account whose `net_equity_wad` decreases (`HealthMonotonicityViolated`).
2. Reject `ref_price == 0` with `InvalidAssetConfig`, use 512-bit cross multiplication (`FullMath512.gtMul512`) for price protection bands, and generalize `lot_step_for_price(p) = max(10^9, 10^18 / gcd(p, 10^18))` for sub-Gwei fractional clearing.
3. Align canonical `Address`-ordered cycle compression, checked `U256` `compressed_volume`, checked `I256` conservation sums, `I256::MIN` negation, active-position `withdraw` oracle staleness, `nonReentrant`, and `sweepFeeVault` across endpoints.
