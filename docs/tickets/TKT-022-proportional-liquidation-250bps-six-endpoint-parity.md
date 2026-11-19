# TKT-022: Six-Endpoint 250 bps Proportional Underwater Liquidation & 512-Bit Overflow Elimination

- **Status**: Completed (`v0.6.0` — Wave 1 Frontier)
- **Blocked by**: None
- **Testing Seam**: Seam S1, Seam S2
- **Governing Contracts**: `CONTEXT.md`, `ADR-0009`, `ADR-0010`, `SPEC-001` (`v0.6.0`)

## Objective & Deliverable Behavior

1. Add pure domain Ubiquitous Language definitions for **强制减仓清算 (`Underwater Liquidation`)** and **最小计量尾差归集 (`Sub-Quantum Dust Sweep`)** to `CONTEXT.md` (`Rule A1`).
2. Author `ADR-0010` and synchronize `ADR-0009`, `SPEC-001`, `README.md`, and `SUBMISSION.md` to lock `LIQUIDATION_BONUS_CAP_BPS = 250` (`min(mm_bps, 250 bps)`), eliminating all `500 bps` documentation drift.
3. Replace 256-bit `mark_price_wad * (10_000 + bonus_bps)` pre-multiplication in `crates/clearing-core/src/engine.rs`, `contracts/src/SolidityClearingBenchmark.sol`, and `tools/ref_sim/engine.py` with two-step 512-bit `mul_div_floor` collateral calculation, and implement **Proportional Cap** ceiling debt back-calculation (`actual_repay = min(capped_repay, mul_div_ceil(mul_div_ceil(avail_coll, 10_000, 10_000 + bonus_bps), coll_price, debt_price))`) whenever `raw_seize > avail_coll` (failing closed with `InvalidIntent` if `actual_seize == 0` or `actual_repay == 0`).
4. Verify via Red-Green TDD across `tests/test_seam_s1_clearing.py`, `crates/clearing-core`, `crates/clearing-stylus` (`TestVM`), and `contracts/test/ClearingDifferential.t.sol`.
