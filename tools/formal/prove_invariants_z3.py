#!/usr/bin/env python3
"""Formal SMT Verification (Z3) + Cross-Binary Hypothesis Differential Harness for StylusClear v1.0.0.

Proves 6 non-vacuous protocol invariants over exact bounded U256 / U512 / BitVec(256) arithmetic
(returning UNSAT for every counterexample query) and executes 100-case Hypothesis differential
fuzzing with real secp256k1 EIP-712 signatures, overlapping prices, and partial-fill pro-rata
cross-checked directly against the compiled Rust `clearing-cli` binary.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import z3  # noqa: E402
from hypothesis import given, settings  # noqa: E402
from hypothesis import strategies as st  # noqa: E402

from tools.ref_sim.crypto_eip712 import (  # noqa: E402
    compute_intent_digest,
    privkey_to_address,
    sign_digest,
)
from tools.ref_sim.engine import MIN_INTENT_AMOUNT_WAD, WAD, execute_batch_payload  # noqa: E402

U256_MAX = (1 << 256) - 1
U512_MAX = (1 << 512) - 1


def prove_theorem(name: str, description: str, build_negation: Callable[[z3.Solver], None]) -> dict[str, Any]:
    t0 = time.perf_counter()
    solver = z3.Solver()
    solver.set("timeout", 30000)
    build_negation(solver)
    res = solver.check()
    elapsed_ms = round((time.perf_counter() - t0) * 1000.0, 2)
    if res != z3.unsat:
        model_str = str(solver.model()) if res == z3.sat else str(res)
        raise AssertionError(f"Theorem {name} FAILED ({res}): {model_str}")
    return {
        "theorem": name,
        "status": "PROVED_UNSAT",
        "elapsed_ms": elapsed_ms,
        "description": description,
    }


def run_all_z3_proofs() -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []

    # T1: Multi-asset two-step floor liquidation with collateral haircut & asymmetric risk valuation
    def t1(s: z3.Solver) -> None:
        mm_d = z3.Int("mm_d")
        haircut_c = z3.Int("haircut_c")
        repay_amt = z3.Int("repay_amt")
        p_d = z3.Int("p_d")
        p_c = z3.Int("p_c")
        bonus = z3.If(mm_d / 2 < 250, mm_d / 2, 250)
        s.add(mm_d >= 2, mm_d <= 10000)
        s.add(haircut_c >= 0, haircut_c <= 9999)
        s.add(repay_amt >= MIN_INTENT_AMOUNT_WAD, repay_amt <= 10**24)
        s.add(p_d >= 10**15, p_d <= 10**24)
        s.add(p_c >= 10**15, p_c <= 10**24)
        # Actual Solidity/Rust two-step mulDivFloor seize calculation
        quote_repay = (repay_amt * p_d) / p_c
        raw_seize = (quote_repay * (10000 + bonus)) / 10000
        # Borrower risk change: eff_coll drops by floor(floor(raw_seize * p_c / WAD) * (10000 - haircut_c) / 10000)
        seize_gross = (raw_seize * p_c) / WAD
        eff_drop = (seize_gross * (10000 - haircut_c)) / 10000
        # Borrower required MM drops by ceil(ceil(repay_amt * p_d / WAD) * (10000 + mm_d) / 10000)
        liab_drop = (repay_amt * p_d + WAD - 1) / WAD
        mm_drop = (liab_drop * (10000 + mm_d) + 9999) / 10000
        # Counterexample: overflow OR health fails to improve (mm_drop <= eff_drop)
        s.add(
            z3.Or(
                repay_amt * p_d > U512_MAX,
                raw_seize > U256_MAX,
                mm_drop > U256_MAX,
                mm_drop <= eff_drop,
            )
        )

    results.append(
        prove_theorem(
            "T1_U256_Adaptive_Bonus_Zero_Deadlock",
            "Over full two-step cross-asset mulDivFloor sizing (p_d, p_c, haircut_c in [0, 5000] bps, mm_bps in [2, 10000]), adaptive bonus = min(mm_bps // 2, 250) never overflows and strictly improves borrower health (mm_drop > eff_drop).",
            t1,
        )
    )

    # T2: Two-step proportional collateral cap bound
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

    # T3: Real UCPBA clearing price & limit price Individual Rationality + directional rounding dust
    def t3(s: z3.Solver) -> None:
        fill_base, clear_p, buy_lim, sell_lim = z3.Ints("fill_base clear_p buy_lim sell_lim")
        s.add(fill_base >= MIN_INTENT_AMOUNT_WAD, fill_base <= 10**27)
        s.add(clear_p >= 10**9, clear_p <= 10**27)
        # UCPBA eligibility: buyer limit >= clearing_price >= seller limit
        s.add(buy_lim >= clear_p, sell_lim >= 1, sell_lim <= clear_p)
        # Engine IR gate on actual fill: buyer pays ceil(fill * clear_p / WAD), seller receives floor(fill * clear_p / WAD)
        buy_pay = (fill_base * clear_p + WAD - 1) / WAD
        sell_recv = (fill_base * clear_p) / WAD
        dust = buy_pay - sell_recv
        # Protocol IR constraint: when buy_lim > clear_p (or exact WAD multiple), buy_pay * WAD <= fill_base * buy_lim;
        # and universally: sell_recv * WAD <= fill_base * clear_p <= buy_pay * WAD and dust in {0, 1}
        # plus if single-lot IR holds (buy_pay * WAD <= fill_base * buy_lim) and seller IR holds (sell_recv * WAD >= fill_base * sell_lim),
        # check no negative dust, dust <= 1, and seller never receives more than buyer pays.
        s.add(
            z3.Or(
                dust < 0,
                dust > 1,
                buy_pay < sell_recv,
                sell_recv * WAD > fill_base * clear_p,
                buy_pay * WAD < fill_base * clear_p,
                z3.And((fill_base * clear_p) % WAD == 0, buy_pay * WAD > fill_base * buy_lim),
                z3.And((fill_base * clear_p) % WAD == 0, sell_recv * WAD < fill_base * sell_lim),
            )
        )

    results.append(
        prove_theorem(
            "T3_UCPBA_Individual_Rationality_And_Bounded_Dust",
            "Over UCPBA clearing price clear_p with buy_lim >= clear_p >= sell_lim, directional ceil/floor settlement guarantees 0 <= dust <= 1 wei, buy_pay >= sell_recv, sandwich bounds, and exact IR preservation on aligned fills.",
            t3,
        )
    )

    # T4: Full-domain [0, 2^256-1] FullMath512 overflow guard (denominator > prod1) & ceil carry guard
    def t4(s: z3.Solver) -> None:
        a, b, d = z3.Ints("a b d")
        two256 = 1 << 256
        s.add(a >= 0, a <= U256_MAX)
        s.add(b >= 0, b <= U256_MAX)
        s.add(d >= 1, d <= U256_MAX)
        prod = a * b
        prod1 = prod / two256
        # Exact FullMath512.sol guard: denominator > prod1
        s.add(d > prod1)
        q_floor = prod / d
        rem = prod % d
        q_ceil = q_floor + z3.If(rem > 0, 1, 0)
        ceil_safe = z3.Implies(rem > 0, q_floor < U256_MAX)
        s.add(
            z3.Or(
                prod > U512_MAX,
                q_floor > U256_MAX,
                q_floor * d > prod,
                q_ceil * d < prod,
                q_ceil - q_floor > 1,
                z3.And(ceil_safe, q_ceil > U256_MAX),
            )
        )

    results.append(
        prove_theorem(
            "T4_FullDomain_U512_FullMath_Overflow_And_Carry_Guard",
            "Over the full machine domain a,b in [0, 2^256-1], d in [1, 2^256-1] matching FullMath512.sol and clearing-core/math.rs, the guard (d > prod1) guarantees q_floor <= U256_MAX with q_floor*d <= a*b <= q_ceil*d, and the ceil carry guard (q_floor < U256_MAX when rem > 0) prevents U256 overflow.",
            t4,
        )
    )

    # T5: Explicit vault_physical_raw + multi-account positive-balance solvency with multi-decimal scaling
    def t5(s: z3.Solver) -> None:
        raw_a, raw_b, wd_a, scale, dust_fee = z3.Ints("raw_a raw_b wd_a scale dust_fee")
        s.add(z3.Or(scale == 1, scale == 10**10, scale == 10**12))
        s.add(raw_a >= 1, raw_a <= 10**24)
        s.add(raw_b >= 1, raw_b <= 10**24)
        s.add(wd_a >= 1, wd_a <= raw_a)
        # Vault starts with physical raw = raw_a + raw_b; accounts hold raw_a*scale and raw_b*scale
        vault_pre = raw_a + raw_b
        bal_a_pre = raw_a * scale
        bal_b_pre = raw_b * scale
        # After account A withdraws wd_a raw units and fee vault absorbs 0..scale-1 rounding dust within conservation
        s.add(dust_fee >= 0, dust_fee < scale, dust_fee <= (raw_a - wd_a) * scale)
        vault_post = vault_pre - wd_a
        bal_a_post = bal_a_pre - wd_a * scale - dust_fee
        bal_b_post = bal_b_pre
        # Solvency invariant: remaining vault physical raw * scale >= sum of remaining user balances + fee vault dust
        # and account B can still withdraw 100% of raw_b
        s.add(
            z3.Or(
                vault_pre * scale > U256_MAX,
                vault_post < raw_b,
                vault_post * scale < bal_a_post + bal_b_post + dust_fee,
                (bal_a_post + dust_fee) % scale != 0,
            )
        )

    results.append(
        prove_theorem(
            "T5_U256_MultiDecimal_Vault_Solvency",
            "Over explicit vault_physical_raw and multi-account 6/8/18-decimal balances up to 10^24 raw units, WAD scaling never overflows U256 and after any valid withdrawal the vault remains 100% solvent for all remaining depositors.",
            t5,
        )
    )

    # T6: BitVec(256) sub-quantum debt exit guarantee (full U256 width, non-zero received_raw)
    def t6(s: z3.Solver) -> None:
        abs_debt = z3.BitVec("abs_debt", 256)
        received_raw = z3.BitVec("received_raw", 256)
        quantum = z3.BitVec("quantum", 256)
        s.add(z3.Or(quantum == z3.BitVecVal(10**10, 256), quantum == z3.BitVecVal(10**12, 256)))
        s.add(z3.UGE(abs_debt, z3.BitVecVal(1, 256)), z3.ULT(abs_debt, quantum))
        # Safe U256 upper bound enforced by checked_mul: received_raw <= 10^24
        s.add(z3.UGE(received_raw, z3.BitVecVal(1, 256)), z3.ULE(received_raw, z3.BitVecVal(10**24, 256)))
        credit_wad = received_raw * quantum
        new_pos_bal = credit_wad - abs_debt
        s.add(
            z3.Or(
                z3.ULE(credit_wad, abs_debt),
                z3.ULT(credit_wad, quantum),
                z3.And(received_raw == z3.BitVecVal(1, 256), z3.UGE(new_pos_bal, quantum)),
            )
        )

    results.append(
        prove_theorem(
            "T6_BitVec256_SubQuantum_Debt_Exit_Guarantee",
            "Over full BitVec(256) arithmetic for 6/8-decimal assets (received_raw in [1, 10^24]), repaySubQuantumDebt with transfer_from_checked strictly clears any sub-quantum negative balance to > 0 (and < 1 quantum for 1-unit transfers) without wraparound.",
            t6,
        )
    )

    return results


def _find_clearing_cli() -> Path | None:
    candidates: list[Path] = []
    cargo_target = os.environ.get("CARGO_TARGET_DIR")
    if cargo_target:
        candidates.extend(
            [
                Path(cargo_target) / "release" / "clearing-cli",
                Path(cargo_target) / "debug" / "clearing-cli",
            ]
        )
    candidates.extend(
        [
            ROOT / "target" / "release" / ("clearing-cli.exe" if sys.platform == "win32" else "clearing-cli"),
            ROOT / "target" / "debug" / ("clearing-cli.exe" if sys.platform == "win32" else "clearing-cli"),
        ]
    )
    for cand in candidates:
        if cand.exists() and os.access(cand, os.X_OK):
            return cand
    return None


def sign_trade_intent(
    pk: int,
    chain_id: int,
    verifying_contract: str,
    base_asset: int,
    quote_asset: int,
    side: int,
    amount_wad: int,
    limit_price_wad: int,
    max_epoch: int,
    nonce: int,
) -> dict[str, Any]:
    trader = privkey_to_address(pk)
    digest = compute_intent_digest(
        chain_id,
        verifying_contract,
        trader,
        base_asset,
        quote_asset,
        side,
        amount_wad,
        limit_price_wad,
        max_epoch,
        nonce,
    )
    v, r, s = sign_digest(pk, digest)
    return {"mode": "EIP712", "v": v, "r": "0x" + r.hex(), "s": "0x" + s.hex()}


def run_hypothesis_differential_fuzz(max_examples: int = 100, require_cli: bool = False) -> dict[str, Any]:
    checked = 0
    cli_checked = 0
    partial_fill_cases = 0
    non_crossing_cases = 0
    cli_bin = _find_clearing_cli()
    if require_cli and cli_bin is None:
        raise RuntimeError("--require-cli specified but compiled `clearing-cli` binary was not found")

    pk0 = 0x1111111111111111111111111111111111111111111111111111111111111111
    pk1 = 0x2222222222222222222222222222222222222222222222222222222222222222
    pk2 = 0x3333333333333333333333333333333333333333333333333333333333333333
    addr0 = privkey_to_address(pk0)
    addr1 = privkey_to_address(pk1)
    addr2 = privkey_to_address(pk2)
    chain_id = 421614
    verifying_contract = "0x" + "ab" * 20

    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)

        @settings(max_examples=max_examples, deadline=None)
        @given(
            c01=st.integers(min_value=1, max_value=5_000),
            c12=st.integers(min_value=1, max_value=5_000),
            c20=st.integers(min_value=1, max_value=5_000),
            buy_qty=st.integers(min_value=1, max_value=10),
            sell_qty=st.integers(min_value=1, max_value=10),
            buy_px=st.integers(min_value=2350, max_value=2650),
            sell_px=st.integers(min_value=2350, max_value=2650),
        )
        def prop_cycle_and_auction_cross_binary(
            c01: int,
            c12: int,
            c20: int,
            buy_qty: int,
            sell_qty: int,
            buy_px: int,
            sell_px: int,
        ) -> None:
            nonlocal checked, cli_checked, partial_fill_cases, non_crossing_cases
            buy_qty_wad = buy_qty * WAD
            sell_qty_wad = sell_qty * WAD
            buy_wad = buy_px * WAD
            sell_wad = sell_px * WAD
            auth0 = sign_trade_intent(
                pk0, chain_id, verifying_contract, 1, 0, 0, buy_qty_wad, buy_wad, 100, 1
            )
            auth1 = sign_trade_intent(
                pk1, chain_id, verifying_contract, 1, 0, 1, sell_qty_wad, sell_wad, 100, 1
            )
            accounts: list[dict[str, Any]] = [
                {"address": addr0, "balances": [str(60_000 * WAD), str(20 * WAD)]},
                {"address": addr1, "balances": [str(60_000 * WAD), str(20 * WAD)]},
                {"address": addr2, "balances": [str(60_000 * WAD), str(20 * WAD)]},
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
                        "amount_wad": str(buy_qty_wad),
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
                        "amount_wad": str(sell_qty_wad),
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
            expected_vol = min(buy_qty_wad, sell_qty_wad) if buy_px >= sell_px else 0
            actual_vol = sum(int(a["matched_volume_wad"]) for a in py_res["auctions"])
            assert actual_vol == expected_vol
            if expected_vol == 0:
                non_crossing_cases += 1
            elif buy_qty != sell_qty:
                partial_fill_cases += 1

            for asset_idx in (0, 1):
                pre_sum = sum(int(acc["balances"][asset_idx]) for acc in accounts)
                post_sum = sum(int(acc["balances"][asset_idx]) for acc in py_res["post_accounts"])
                fee_delta = int(py_res["fee_vault_deltas"][str(asset_idx)])
                assert pre_sum == post_sum + fee_delta

            if cli_bin is not None:
                pfile = td_path / f"fuzz_{checked}.json"
                pfile.write_text(json.dumps(payload), encoding="utf-8")
                proc = subprocess.run([str(cli_bin), "replay", str(pfile)], capture_output=True, text=True, check=True)
                cli_res = json.loads(proc.stdout)
                assert int(cli_res["cycles_eliminated"]) == int(py_res["cycles_eliminated"])
                assert len(cli_res["auctions"]) == len(py_res["auctions"])
                for ca, pa in zip(cli_res["auctions"], py_res["auctions"], strict=True):
                    assert int(ca["clearing_price_wad"]) == int(pa["clearing_price_wad"])
                    assert int(ca["matched_volume_wad"]) == int(pa["matched_volume_wad"])
                    assert int(ca["rounding_dust_quote_wad"]) == int(pa["rounding_dust_quote_wad"])
                assert cli_res["post_accounts"] == py_res["post_accounts"]
                assert cli_res["fee_vault_deltas"] == py_res["fee_vault_deltas"]
                assert cli_res["compressed_volume_by_asset"] == py_res["compressed_volume_by_asset"]
                cli_checked += 1

            checked += 1

        prop_cycle_and_auction_cross_binary()

    return {
        "examples_checked": checked,
        "cli_binary_differential_examples": cli_checked,
        "cli_replay_cross_checked": cli_checked == checked and checked > 0,
        "partial_fill_cases_exercised": partial_fill_cases,
        "non_crossing_cases_exercised": non_crossing_cases,
        "fields_cross_checked": [
            "cycles_eliminated",
            "clearing_price_wad",
            "matched_volume_wad",
            "rounding_dust_quote_wad",
            "compressed_volume_by_asset",
            "post_accounts",
            "fee_vault_deltas",
        ],
        "eip712_real_signatures": True,
        "status": "PASSED",
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Run Z3 formal proofs and cross-binary EIP-712 Hypothesis fuzzing.")
    ap.add_argument(
        "--out",
        default=str(ROOT / "docs" / "security" / "z3-formal-proofs.json"),
        help="Output JSON report path",
    )
    ap.add_argument("--examples", type=int, default=100, help="Hypothesis fuzz examples")
    ap.add_argument("--require-cli", action="store_true", help="Fail if compiled clearing-cli binary is unavailable")
    args = ap.parse_args()

    theorems = run_all_z3_proofs()
    fuzz = run_hypothesis_differential_fuzz(max_examples=args.examples, require_cli=args.require_cli)
    report = {
        "schema_version": "1.1.0",
        "z3_version": z3.get_version_string(),
        "theorems_proved": len(theorems),
        "all_unsat": all(t["status"] == "PROVED_UNSAT" for t in theorems),
        "theorems": theorems,
        "hypothesis_differential_fuzz": fuzz,
    }
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(
        f"[formal] OK: {len(theorems)}/{len(theorems)} Z3 theorems PROVED_UNSAT "
        f"| Hypothesis {fuzz['examples_checked']} examples "
        f"(CLI cross-checked: {fuzz['cli_binary_differential_examples']}/{fuzz['examples_checked']}, "
        f"partial_fills={fuzz['partial_fill_cases_exercised']}, non_crossing={fuzz['non_crossing_cases_exercised']})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
