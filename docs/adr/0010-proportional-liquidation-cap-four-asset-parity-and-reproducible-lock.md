# ADR-0010: Proportional Underwater Liquidation Cap (250 bps, 512-Bit Overflow-Free), Four-Asset Live RWA Slot Parity & Reproducible Lockfile

- **Status**: Accepted (`v0.6.0`)
- **Date**: 2026-11-18
- **Supersedes / Extends**: `ADR-0007`, `ADR-0008`, `ADR-0009`

## Context

Final audit review of `StylusClear v0.5.0` surfaced five remaining hardening gaps (`H-01` through `H-05`):

1. **`H-01` — Documentation Drift on Liquidation Bonus Cap**: Production implementations (`crates/clearing-core`, `SolidityClearingBenchmark.sol`, `tools/ref_sim/engine.py`) enforced `LIQUIDATION_BONUS_CAP_BPS = 250` (`2.50%`), whereas `ADR-0009` and `README.md` still cited `legacy 500-bps bonus cap`.
2. **`H-02` — 256-Bit Pre-Multiplication Overflow & Uncapped Debt Repayment When Collateral Is Short**: In `execute_underwater_liquidation` / `liquidate()`, pre-multiplying `mark_price_wad * (10_000 + bonus_bps)` in 256-bit arithmetic risked premature `MathOverflow` on ultra-large synthetic prices, and clamping `actual_seize = min(raw_seize, avail_coll)` without proportionally scaling down `actual_repay` forced liquidators to repay full `capped_repay` debt while receiving less than the fair collateral value whenever `raw_seize > avail_coll`.
3. **`H-04` — Live RPC Revert on Scenario 4 (`robinhoodUsdgMesh`)**: Arbitrum Sepolia deployment scripts registered only three assets (`0: USDC`, `1: WETH`, `2: ARB`), and `buildLiveScenarioPayloads` reused WETH/USDC payloads for Scenario 4 instead of clearing a dedicated 4th tokenized RWA equity slot (`assetId = 3`, `rwaMock18` @ `$140.00`) against the 6-decimal `USDG`/`USDC` slot (`assetId = 0`).
4. **`H-03` & `H-05` — Port Drift (`4173` vs `8080`), Shared Entity Bundle Autoload & Unpinned `Cargo.lock`**: `docs/DEMO_VIDEO_SCRIPT.md` referenced `legacy port 4173` while `web/package.json` served on `:8080`; `scripts/check.sh` did not auto-mount the shared `代码任务所需实体` chunked toolchain repository (`bootstrap_sandbox.py --modules 01,02,03,06,07`); and root `Cargo.lock` / `cargo build --locked` was absent from `Dockerfile.stylus-reproducible`.

## Decision

1. **D1 — Six-Endpoint `250 bps` Cap & Two-Step 512-Bit Proportional Liquidation Formula**:
   - Standardize `LIQUIDATION_BONUS_CAP_BPS = 250` (`bonus_bps = min(debt_asset.mm_bps, 250)`) across all code and documentation (`clearing-core`, `clearing-stylus`, `SolidityClearingBenchmark.sol`, `tools/ref_sim/engine.py`, `ADR-0009`, `ADR-0010`, `SPEC-001`, `README.md`, `SUBMISSION.md`).
   - Eliminate 256-bit pre-multiplication overflow by computing collateral seizure via two nested 512-bit `mul_div_floor` steps across Rust (`U512`), Solidity (`FullMath512`), and Python (`ref_sim`):
     - `capped_repay = min(repay_amount_wad, abs_debt)`
     - `quote_repay = mul_div_floor(capped_repay, debt_mark_price_wad, collateral_mark_price_wad)`
     - `raw_seize = mul_div_floor(quote_repay, 10_000 + bonus_bps, 10_000)`
   - Enforce **Proportional Cap** when `raw_seize > avail_coll`:
     - If `raw_seize <= avail_coll`: `actual_repay = capped_repay`, `actual_seize = raw_seize`.
     - If `raw_seize > avail_coll`: `actual_seize = avail_coll`, and back-compute `actual_repay` using ceiling rounding so underwater net equity is protected while liquidator incentive is preserved:
       `actual_repay = min(capped_repay, mul_div_ceil(mul_div_ceil(avail_coll, 10_000, 10_000 + bonus_bps), collateral_mark_price_wad, debt_mark_price_wad))`.
     - Reject with `InvalidIntent` if `actual_seize == 0` or `actual_repay == 0`.
2. **D2 — Four-Asset Sepolia Slot (`assetId = 3`, `rwaMock18` @ `$140`) & Live Scenario 4 Parity**:
   - Register `assetId = 3` (`rwaMock18`, 18 decimals, mark price `140 * 10^18`, `haircut_bps = 1000`, `im_bps = 1200`, `mm_bps = 600`) in `scripts/deploy-sepolia.sh`, `scripts/demo-sepolia-live.sh`, `deployments/arbitrum-sepolia.json`, `web/deployments/arbitrum-sepolia.json`, `web/engine-ui.mjs`, and `web/index.html`.
   - Seed `DEMO_A_ADDR` and `DEMO_B_ADDR` with `assetId = 3` collateral in `demo-sepolia-live.sh`, and update `PRESET_SCENARIOS.robinhoodUsdgMesh` + `buildDomainSignedLivePayload` so Scenario 4 settles `assetId = 3` (`NVDAx` / tokenized equity) against `assetId = 0` (`USDG`/`USDC` 6d) with zero live RPC reverts across all 4 presets.
3. **D3 — `代码任务所需实体` Auto-Mount, Port `8080` Unification & Reproducible `Cargo.lock`**:
   - Teach `scripts/check.sh` and `scripts/wsl2-oneclick-finish.sh` to auto-discover `STYLUSCLEAR_ENTITY_DIR` or `../代码任务所需实体/manifest.json` and run `bootstrap_sandbox.py --dst "$HOME/.cache/stylusclear_entity_sandbox" --modules 01,02,03,06,07` (preserving `.vm_deps/stylus_web_bundle.tar.xz` compatibility and preserving `arbitrum_sepolia_onchain_verified` status during `--ingest-host-logs`).
   - Standardize workbench port to `8080` everywhere (`docs/DEMO_VIDEO_SCRIPT.md` + `archcheck`), commit root `Cargo.lock`, and enforce `COPY Cargo.toml Cargo.lock Stylus.toml ./` + `cargo build --locked --release --target wasm32-unknown-unknown -p clearing-stylus` in `Dockerfile.stylus-reproducible`.

## Consequences

- Partial and collateral-capped underwater liquidations match bit-for-bit across Rust `clearing-core`, `StylusClearingEngine` (`TestVM`), `SolidityClearingBenchmark` (Foundry), and `tools/ref_sim`.
- All 4 workbench scenarios (`institutionalMesh`, `unsignedObligationAttack`, `undercollateralizedRollback`, `robinhoodUsdgMesh`) execute deterministically offline and via dual-contract JSON-RPC (`Seam S3`).
- `tools/archcheck/check.py --strict` and `tests/test_seam_s4_archcheck.py` permanently guard against `legacy 500-bps bonus cap`, `legacy port 4173`, missing `Cargo.lock`, or unlocked Docker WASM builds.
