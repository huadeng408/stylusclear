#!/usr/bin/env python3
"""Formal SMT invariant verification (Z3 U256/U512 bounded + BitVec) & cross-binary Hypothesis differential fuzzing (StylusClear v0.9.0)."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import z3
from hypothesis import given, settings
from hypothesis import strategies as st

from tools.ref_sim.crypto_eip712 import privkey_to_address, sign_trade_intent
from tools.ref_sim.engine import MIN_INTENT_AMOUNT_WAD, WAD, execute_batch_payload

U256_MAX = (1 << 256) - 1
U512_MAX = (1 << 512) - 1


def prove_theorem(name: str, description: str, build_negation: Callable[[z3.Solver], None]) -> dict[str, Any]:
    t0 = time.perf_counter()
    solver = z3.Solver()
    solver.set("timeout", 15000)
    build_negation(solver)
    res = solver.check()
    elapsed_ms = round((time.perf_counter() - t0) * 1000.0, 2)
    if res != z3.unsat:
        model = str(solver.model()) if res == z3.sat else "unknown"
        raise AssertionError(f"Formal proof {name} FAILED ({res}): {model}")
    return {
        "theorem": name,
        "description": description,
        "status": "PROVED_UNSAT",
        "solver": f"z3-solver {z3.get_version_string()}",
        "elapsed_ms": elapsed_ms,
    }


def run_all_z3_proofs() -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []

    def t1(s: z3.Solver) -> None:
        mm_d = z3.Int("mm_d")
        repay_val = z3.Int("repay_val")
        bonus = z3.If(mm_d / 2 < 250, mm_d / 2, 250)
        s.add(mm_d >= 2, mm_d <= 10000)
        s.add(repay_val >= 10**9, repay_val <= 10**30)
        seize_num = repay_val * (10000 + bonus)
        mm_num = repay_val * (10000 + mm_d) + 9999
        seize_val = seize_num / 10000
        mm_drop = mm_num / 10000
        s.add(z3.Or(seize_num > U256_MAX, mm_num > U256_MAX, mm_drop <= seize_val))

    results.append(
        prove_theorem(
            "T1_U256_Adaptive_Bonus_Zero_Deadlock",
            "For any debt asset with mm_bps in [2, 10000] (enforced by configureAsset) and zero-haircut stablecoin collateral, bonus = min(mm_bps // 2, 250) never overflows U256 and strictly improves borrower health (mm_drop > seize_val).",
            t1,
        )
    )

    def t2(s: z3.Solver) -> None:
        avail_coll = z3.Int("avail_coll")
        bonus = z3.Int("bonus")
        p_c = z3.Int("p_c")
        p_d = z3.Int("p_d")
        s.add(avail_coll >= 1, avail_coll <= 10**27)
        s.add(bonus >= 1, bonus <= 250)
        s.add(p_c >= 10**15, p_c <= 10**24)
        s.add(p_d >= 10**15, p_d <= 10**24)
        max_quote = (avail_coll * 10000) / (10000 + bonus)
        back_repay = (max_quote * p_c) / p_d
        s.add(back_repay >= MIN_INTENT_AMOUNT_WAD)
        lhs = back_repay * p_d * (10000 + bonus)
        rhs = avail_coll * p_c * 10000
        upper_bound = (back_repay + 1) * p_d * (10000 + bonus) + p_c * (10000 + bonus)
        s.add(z3.Or(lhs > rhs, rhs >= upper_bound))

    results.append(
        prove_theorem(
            "T2_Floor_Proportional_Cap_Bound",
            "When raw_seize > avail_coll, two-step floor back-calculation guarantees back_repay * p_d * (10000 + bonus) <= avail_coll * p_c * 10000 AND strictly bounds borrower rounding loss to < 2 rounding quanta.",
            t2,
        )
    )

    def t3(s: z3.Solver) -> None:
        q1, r1, qN, rN = z3.Ints("q1 r1 qN rN")
        s.add(q1 >= 0, r1 >= 0, r1 < WAD)
        s.add(qN >= 0, rN >= 0, rN < WAD)
        buy_1 = q1 + z3.If(r1 > 0, 1, 0)
        sell_1 = q1
        buy_N = qN + z3.If(rN > 0, 1, 0)
        sell_N = qN
        carry = z3.If(rN + r1 >= WAD, 1, 0)
        rem_sum = rN + r1 - carry * WAD
        buy_Np1 = (qN + q1 + carry) + z3.If(rem_sum > 0, 1, 0)
        sell_Np1 = qN + q1 + carry
        dust_Np1 = buy_Np1 - sell_Np1
        s.add(z3.Or(dust_Np1 < 0, dust_Np1 > 1, buy_Np1 > buy_N + buy_1, sell_Np1 < sell_N + sell_1))

    results.append(
        prove_theorem(
            "T3_UCPBA_Lot_SubAdditivity_And_Bounded_Dust",
            "Inductive Euclidean proof over arbitrary N >= 1 UCPBA lots: buyer ceil-notional is sub-additive, seller floor-notional is super-additive, and per-pair rounding dust is strictly in {0, 1} wei.",
            t3,
        )
    )

    def t4(s: z3.Solver) -> None:
        a, b, d = z3.Ints("a b d")
        s.add(a >= 0, a <= 10**36)
        s.add(b >= 0, b <= 10**36)
        s.add(d >= 1, d <= 10**36)
        prod = a * b
        q_floor = prod / d
        rem = prod % d
        q_ceil = q_floor + z3.If(rem > 0, 1, 0)
        s.add(
            z3.Or(
                prod > U512_MAX,
                q_ceil > U256_MAX,
                q_floor * d > prod,
                q_ceil * d < prod,
                q_ceil - q_floor > 1,
            )
        )

    results.append(
        prove_theorem(
            "T4_U512_FullMath_NoOverflow_And_Sandwich",
            "Over exact 512-bit intermediate arithmetic (FullMath512.sol & clearing-core/math.rs), mul_div_floor and mul_div_ceil for all a,b,d <= 10^36 never overflow U512/U256, satisfy q_floor*d <= a*b <= q_ceil*d, and differ by at most 1 wei.",
            t4,
        )
    )

    def t5(s: z3.Solver) -> None:
        raw_dep, raw_wd, scale = z3.Ints("raw_dep raw_wd scale")
        s.add(z3.Or(scale == 1, scale == 10**10, scale == 10**12))
        s.add(raw_dep >= 1, raw_dep <= 10**24)
        s.add(raw_wd >= 1, raw_wd <= raw_dep)
        wad_dep = raw_dep * scale
        wad_wd = raw_wd * scale
        rem_wad = wad_dep - wad_wd
        rem_raw = raw_dep - raw_wd
        s.add(
            z3.Or(
                wad_dep > U256_MAX,
                wad_wd > wad_dep,
                rem_wad / scale != rem_raw,
                rem_wad % scale != 0,
            )
        )

    results.append(
        prove_theorem(
            "T5_U256_MultiDecimal_Vault_Exactness",
            "For 6/8/18-decimal ERC-20 tokens up to 10^24 raw units, WAD scaling never overflows U256 and exact raw<->WAD withdrawal subtraction preserves exact quantum alignment with zero dust leakage.",
            t5,
        )
    )

    def t6(s: z3.Solver) -> None:
        abs_debt = z3.BitVec("abs_debt", 64)
        received_raw = z3.BitVec("received_raw", 64)
        quantum = z3.BitVec("quantum", 64)
        s.add(z3.Or(quantum == z3.BitVecVal(10**10, 64), quantum == z3.BitVecVal(10**12, 64)))
        s.add(z3.UGE(abs_debt, z3.BitVecVal(1, 64)), z3.ULT(abs_debt, quantum))
        s.add(z3.UGE(received_raw, z3.BitVecVal(1, 64)), z3.ULE(received_raw, z3.BitVecVal(10, 64)))
        credit_wad = received_raw * quantum
        new_pos_bal = credit_wad - abs_debt
        s.add(
            z3.Or(
                z3.ULE(credit_wad, abs_debt),
                z3.And(received_raw == z3.BitVecVal(1, 64), z3.UGE(new_pos_bal, quantum)),
            )
        )

    results.append(
        prove_theorem(
            "T6_BitVec64_SubQuantum_Debt_Exit_Guarantee",
            "Over 64-bit unsigned bitvectors for 6/8-decimal assets, repaySubQuantumDebt with transfer_from_checked(received_raw >= 1) strictly clears any sub-quantum negative balance to > 0 (and < 1 quantum for standard 1-unit transfers) without wraparound.",
            t6,
        )
    )

    return results


def locate_cli_binary() -> Path | None:
    env_bin = os.environ.get("CLEARING_CLI_BIN")
    if env_bin and Path(env_bin).is_file():
        return Path(env_bin)
    target_dir = os.environ.get("CARGO_TARGET_DIR")
    candidates: list[Path] = []
    if target_dir:
        candidates.append(Path(target_dir) / "release" / "clearing-cli")
        candidates.append(Path(target_dir) / "debug" / "clearing-cli")
    candidates.extend([
        ROOT / "target" / "release" / "clearing-cli",
        ROOT / "target" / "debug" / "clearing-cli",
    ])
    for cand in candidates:
        if cand.is_file():
            return cand
    found = shutil.which("clearing-cli")
    return Path(found) if found else None


def run_hypothesis_differential_fuzz(cli_bin: Path | None) -> dict[str, Any]:
    checked = 0
    cli_checked = 0
    max_examples = 50
    chain_id = 421614
    verifying_contract = "0x2222222222222222222222222222222222222222"
    pk0, pk1, pk2 = 0x9101, 0x9102, 0x9103
    addr0 = privkey_to_address(pk0)
    addr1 = privkey_to_address(pk1)
    addr2 = privkey_to_address(pk2)

    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)

        @settings(max_examples=max_examples, deadline=None)
        @given(
            c01=st.integers(min_value=1, max_value=5_000),
            c12=st.integers(min_value=1, max_value=5_000),
            c20=st.integers(min_value=1, max_value=5_000),
            order_qty=st.integers(min_value=1, max_value=10),
            buy_px=st.integers(min_value=2500, max_value=2600),
            sell_px=st.integers(min_value=2400, max_value=2500),
        )
        def prop_cycle_and_auction_cross_binary(
            c01: int, c12: int, c20: int, order_qty: int, buy_px: int, sell_px: int
        ) -> None:
            nonlocal checked, cli_checked
            qty_wad = order_qty * WAD
            buy_wad = buy_px * WAD
            sell_wad = sell_px * WAD
            auth0 = sign_trade_intent(
                pk0, chain_id, verifying_contract, 1, 0, 0, qty_wad, buy_wad, 100, 1
            )
            auth1 = sign_trade_intent(
                pk1, chain_id, verifying_contract, 1, 0, 1, qty_wad, sell_wad, 100, 1
            )
            accounts: list[dict[str, Any]] = [
                {"address": addr0, "balances": [str(50_000 * WAD), str(20 * WAD)]},
                {"address": addr1, "balances": [str(50_000 * WAD), str(20 * WAD)]},
                {"address": addr2, "balances": [str(50_000 * WAD), str(20 * WAD)]},
            ]
            payload: dict[str, Any] = {
                "batch_epoch": 42,
                "block_timestamp": 1000,
                "max_price_staleness": 3600,
                "max_price_deviation_bps": 2000,
                "chain_id": chain_id,
                "verifying_contract": verifying_contract,
                "caller": "0x9999000000000000000000000000000000000099",
                "assets": [
                    {
                        "asset_id": 0,
                        "symbol": "USDC",
                        "decimals": 6,
                        "mark_price_wad": str(WAD),
                        "price_updated_at": 990,
                        "haircut_bps": 0,
                        "im_bps": 1000,
                        "mm_bps": 500,
                    },
                    {
                        "asset_id": 1,
                        "symbol": "WETH",
                        "decimals": 18,
                        "mark_price_wad": str(2500 * WAD),
                        "price_updated_at": 990,
                        "haircut_bps": 1000,
                        "im_bps": 1000,
                        "mm_bps": 500,
                    },
                ],
                "accounts": accounts,
                "confirmed_obligations": {
                    "0:1:0": str(c01 * WAD),
                    "1:2:0": str(c12 * WAD),
                    "2:0:0": str(c20 * WAD),
                },
                "obligations": [
                    {"debtor": 0, "creditor": 1, "asset_id": 0, "amount_wad": str(c01 * WAD), "auth": {"mode": "LEDGER"}},
                    {"debtor": 1, "creditor": 2, "asset_id": 0, "amount_wad": str(c12 * WAD), "auth": {"mode": "LEDGER"}},
                    {"debtor": 2, "creditor": 0, "asset_id": 0, "amount_wad": str(c20 * WAD), "auth": {"mode": "LEDGER"}},
                ],
                "intents": [
                    {
                        "trader": 0,
                        "base_asset": 1,
                        "quote_asset": 0,
                        "side": "BUY",
                        "amount_wad": str(qty_wad),
                        "limit_price_wad": str(buy_wad),
                        "max_epoch": 100,
                        "nonce": "1",
                        "auth": auth0,
                    },
                    {
                        "trader": 1,
                        "base_asset": 1,
                        "quote_asset": 0,
                        "side": "SELL",
                        "amount_wad": str(qty_wad),
                        "limit_price_wad": str(sell_wad),
                        "max_epoch": 100,
                        "nonce": "1",
                        "auth": auth1,
                    },
                ],
                "nonce_bitmaps": {},
            }
            py_res = execute_batch_payload(payload)
            assert int(py_res["cycles_eliminated"]) == 1
            assert sum(int(a["matched_volume_wad"]) for a in py_res["auctions"]) == qty_wad

            for asset_idx in (0, 1):
                pre_sum = sum(int(acc["balances"][asset_idx]) for acc in accounts)
                post_sum = sum(int(acc["balances"][asset_idx]) for acc in py_res["post_accounts"])
                fee_delta = int(py_res["fee_vault_deltas"][asset_idx])
                assert pre_sum == post_sum + fee_delta

            if cli_bin is not None:
                pfile = td_path / f"fuzz_{checked}.json"
                pfile.write_text(json.dumps(payload), encoding="utf-8")
                proc = subprocess.run([str(cli_bin), "replay", str(pfile)], capture_output=True, text=True, check=True)
                cli_res = json.loads(proc.stdout)
                assert int(cli_res["cycles_eliminated"]) == int(py_res["cycles_eliminated"])
                assert len(cli_res["auctions"]) == len(py_res["auctions"])
                for ca, pa in zip(cli_res["auctions"], py_res["auctions"]):
                    assert int(ca["clearing_price_wad"]) == int(pa["clearing_price_wad"])
                    assert int(ca["matched_volume_wad"]) == int(pa["matched_volume_wad"])
                    assert int(ca["dust_wad"]) == int(pa["dust_wad"])
                assert cli_res["post_accounts"] == py_res["post_accounts"]
                assert cli_res["fee_vault_deltas"] == py_res["fee_vault_deltas"]
                cli_checked += 1

            checked += 1

        prop_cycle_and_auction_cross_binary()

    return {
        "examples_checked": checked,
        "cli_binary_differential_examples": cli_checked,
        "cli_replay_cross_checked": cli_checked == checked and checked > 0,
        "fields_cross_checked": [
            "cycles_eliminated",
            "clearing_price_wad",
            "matched_volume_wad",
            "dust_wad",
            "post_accounts",
            "fee_vault_deltas",
        ],
    }


def main() -> int:
    z3_results = run_all_z3_proofs()
    cli_bin = locate_cli_binary()
    hyp_result = run_hypothesis_differential_fuzz(cli_bin)

    out_path = ROOT / "docs" / "security" / "z3-formal-proofs.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "schema_version": "0.9.0",
        "solver": f"z3-solver {z3.get_version_string()}",
        "theorems_proved": len(z3_results),
        "all_unsat": all(r["status"] == "PROVED_UNSAT" for r in z3_results),
        "theorems": z3_results,
        "hypothesis_differential": hyp_result,
    }
    out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        f"[formal-z3] OK ({len(z3_results)}/6 PROVED_UNSAT, "
        f"{hyp_result['examples_checked']} Hypothesis examples, "
        f"{hyp_result['cli_binary_differential_examples']} Rust clearing-cli cross-checked)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
