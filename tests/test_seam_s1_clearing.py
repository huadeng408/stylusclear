"""Seam S1 tests: v0.7.0 clearing, 2-Origin BFS cycle netting, 512-bit UCPBA IR, and adaptive floor liquidation."""
from __future__ import annotations

import pytest

from tools.ref_sim.engine import (
    AssetRiskConfig,
    ClearingEngineError,
    ObligationEdge,
    WAD,
    compress_obligation_cycles,
    compute_liquidation_bonus_bps,
    evaluate_account_risk,
    execute_batch_payload,
    execute_underwater_liquidation,
)


def _std_assets() -> list[AssetRiskConfig]:
    return [
        AssetRiskConfig(0, 6, 1 * WAD, 1_700_000_050, 0, 500, 250),       # USDC/USDG
        AssetRiskConfig(1, 18, 2850 * WAD, 1_700_000_050, 500, 1000, 500), # WETH
        AssetRiskConfig(2, 18, 1 * WAD, 1_700_000_050, 1000, 1200, 600),   # ARB
        AssetRiskConfig(3, 18, 140 * WAD, 1_700_000_050, 1000, 1200, 600), # NVDAx
    ]


def test_s1_partial_and_capped_liquidation_plus_usdc_zero_deadlock() -> None:
    assets = _std_assets()
    assert compute_liquidation_bonus_bps(500) == 250
    assert compute_liquidation_bonus_bps(250) == 125  # D-07 adaptive cap prevents USDC deadlock!

    # 1) Uncapped partial liquidation (WETH debt -> 250 bps bonus)
    # Underwater: +2,900 USDC, -1.0 WETH (@ $2,850 -> liab 2,850, req_mm = 2,850 * 1.05 = 2,992.5 -> health = -92.5)
    u_bals = [2900 * WAD, -1 * WAD, 0, 0]
    l_bals = [10_000 * WAD, 5 * WAD, 0, 0]
    out = execute_underwater_liquidation(1_700_000_100, 3600, assets, u_bals, l_bals, 1, 0, 4 * 10**17)
    assert out.repaid_debt_wad == 4 * 10**17
    assert out.seized_collateral_wad == 11685 * 10**17  # 0.4 * 2850 * 1.025 = 1,168.50 USDC
    assert evaluate_account_risk(out.post_underwater_balances, assets).health_wad > evaluate_account_risk(u_bals, assets).health_wad

    # 2) Proportional floor cap when collateral is 1,000 USDC (< raw_seize)
    u_low = [1000 * WAD, -1 * WAD, 0, 0]
    out_cap = execute_underwater_liquidation(1_700_000_100, 3600, assets, u_low, l_bals, 1, 0, 1 * WAD)
    assert out_cap.seized_collateral_wad == 1000 * WAD
    assert out_cap.repaid_debt_wad < 1 * WAD
    for a in range(4):
        assert u_low[a] + l_bals[a] == out_cap.post_underwater_balances[a] + out_cap.post_liquidator_balances[a]

    # 3) D-07 regression: USDC debt (mm_bps=250 -> bonus=125) backed by zero-haircut collateral never deadlocks
    assets_two_stables = [
        AssetRiskConfig(0, 6, 1 * WAD, 1_700_000_050, 0, 500, 250),
        AssetRiskConfig(1, 6, 1 * WAD, 1_700_000_050, 0, 500, 250),
    ]
    u_stable = [1010 * WAD, -1000 * WAD]  # eff = 1010, req_mm = 1025 -> health = -15
    l_stable = [5000 * WAD, 5000 * WAD]
    out_st = execute_underwater_liquidation(1_700_000_100, 3600, assets_two_stables, u_stable, l_stable, 1, 0, 500 * WAD)
    assert out_st.repaid_debt_wad == 500 * WAD
    assert out_st.seized_collateral_wad == int(500 * WAD * 10125 // 10000)

    # 4) D-17 regression: unbacked liquidator rejected with InsufficientWithdrawableBalance
    with pytest.raises(ClearingEngineError) as exc:
        execute_underwater_liquidation(1_700_000_100, 3600, assets, u_bals, [10_000 * WAD, 0, 0, 0], 1, 0, 4 * 10**17)
    assert exc.value.code == "InsufficientWithdrawableBalance"


def test_s1_two_origin_bfs_prefers_multilateral_cycle_and_selective_oracle() -> None:
    addrs = ["0x" + f"{i+1:02x}" * 20 for i in range(3)]
    # 0->1 (100), 1->0 (100), 1->2 (100), 2->0 (100): 3-cycle 0->1->2->0 eliminates 300 gross vs 200 2-cycle!
    obs = [
        ObligationEdge(0, 1, 0, 100 * WAD),
        ObligationEdge(1, 0, 0, 100 * WAD),
        ObligationEdge(1, 2, 0, 100 * WAD),
        ObligationEdge(2, 0, 0, 100 * WAD),
    ]
    comp = compress_obligation_cycles(addrs, 1, obs)
    assert comp.cycles_eliminated == 1
    assert comp.compressed_volume_by_asset[0] == 300 * WAD
    assert len(comp.residual_obligations) == 1
    assert comp.residual_obligations[0].amount_wad == 100 * WAD

    # D-30: unused asset 3 has stale oracle timestamp (0), active assets 0 & 1 are fresh -> batch still clears!
    payload = {
        "batch_epoch": 1,
        "block_timestamp": 1_700_000_100,
        "max_price_staleness": 3600,
        "max_price_deviation_bps": 2000,
        "chain_id": 421614,
        "verifying_contract": "0x" + "99" * 20,
        "caller": addrs[0],
        "assets": [
            {"asset_id": 0, "decimals": 6, "mark_price_wad": 1 * WAD, "price_updated_at": 1_700_000_090, "haircut_bps": 0, "im_bps": 500, "mm_bps": 250},
            {"asset_id": 1, "decimals": 18, "mark_price_wad": 2500 * WAD, "price_updated_at": 1_700_000_090, "haircut_bps": 500, "im_bps": 1000, "mm_bps": 500},
            {"asset_id": 2, "decimals": 18, "mark_price_wad": 140 * WAD, "price_updated_at": 100, "haircut_bps": 1000, "im_bps": 1200, "mm_bps": 600},
        ],
        "accounts": [
            {"address": addrs[0], "balances": [10_000 * WAD, 5 * WAD, 0]},
            {"address": addrs[1], "balances": [10_000 * WAD, 5 * WAD, 0]},
        ],
        "confirmed_obligations": [{"debtor": 0, "creditor": 1, "asset_id": 0, "amount_wad": 250 * WAD}],
        "obligations": [{"debtor": 0, "creditor": 1, "asset_id": 0, "amount_wad": 250 * WAD, "auth_mode": 0}],
        "intents": [],
    }
    res = execute_batch_payload(payload)
    assert res["cycles_eliminated"] == 0
