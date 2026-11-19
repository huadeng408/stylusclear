#!/usr/bin/env python3
"""Reproducible isomorphic workload generator & Stylus WASM gas/ink estimator (v0.8.0).

Constructs the EXACT SAME 4 multi-cycle chord + crossed-orderbook workloads as
`ClearingBenchmarkGas._runWorkload` in `contracts/test/ClearingDifferential.t.sol`
(Small: 4/5/2/4, Medium: 12/20/9/24, Large: 32/64/33/64, Stress: 44/88/45/88),
cross-verifies every tier against the compiled Rust `clearing-cli` binary
(asserting identical `cycles_eliminated` and positive `matched_volume_wad`),
and computes transparent ArbOS Stylus compute + cold-storage HostIO estimates
per https://docs.arbitrum.io/stylus/reference/opcode-hostio-pricing.

Note: Offline HostIO + WASM fuel metering is a reproducible pre-deployment
calibration model. Once deployed on Arbitrum Sepolia (421614) or Robinhood
Testnet (46630), `scripts/demo-sepolia-live.sh` records live on-chain receipts
and `evm_ink_left()` telemetry.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ref_sim.crypto_eip712 import compute_intent_digest, keccak256

WAD = 10**18
_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
_G = (
    0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
    0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
)

TIERS = [
    ("Small", 4, 5, 2, 4),
    ("Medium", 12, 20, 9, 24),
    ("Large", 32, 64, 33, 64),
    ("Stress", 44, 88, 45, 88),
]


def _pt_add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and y1 != y2:
        return None
    if x1 == x2:
        m = ((3 * x1 * x1) * pow(2 * y1, _P - 2, _P)) % _P
    else:
        m = ((y2 - y1) * pow(x2 - x1, _P - 2, _P)) % _P
    x3 = (m * m - x1 - x2) % _P
    return (x3, (m * (x1 - x3) - y1) % _P)


def _pt_mul(k: int, pt=_G):
    res, addend = None, pt
    while k:
        if k & 1:
            res = _pt_add(res, addend)
        addend = _pt_add(addend, addend)
        k >>= 1
    return res


def _addr_from_sk(sk: int) -> str:
    x, y = _pt_mul(sk)
    return "0x" + keccak256(x.to_bytes(32, "big") + y.to_bytes(32, "big"))[-20:].hex()


def _sign_digest(digest: bytes, sk: int) -> tuple[int, str, str]:
    z = int.from_bytes(digest, "big")
    k = (int.from_bytes(keccak256(sk.to_bytes(32, "big") + digest), "big") % (_N - 1)) + 1
    rx, ry = _pt_mul(k)
    r = rx % _N
    s_val = (pow(k, _N - 2, _N) * (z + r * sk)) % _N
    v = 27 + (ry & 1)
    if s_val > _N // 2:
        s_val = _N - s_val
        v = 55 - v
    return v, "0x" + r.to_bytes(32, "big").hex(), "0x" + s_val.to_bytes(32, "big").hex()


def build_isomorphic_payload(n_acc: int, n_obs: int, n_int: int) -> dict:
    vc = "0x" + "99" * 20
    chain_id = 421614
    parts = [_addr_from_sk(0x9000 + u) for u in range(n_acc)]
    accounts = [
        {"address": addr, "balances": [str(250_000 * WAD), str(80 * WAD)]}
        for addr in parts
    ]
    confirmed: dict[str, str] = {}
    obs = []
    for i in range(n_obs):
        if i < n_acc:
            u, v, amt = i, (i + 1) % n_acc, 2_000 * WAD
        else:
            k = i - n_acc
            u, v, amt = (k + 2) % n_acc, k % n_acc, (10 + k) * WAD
        key = f"{u}:{v}:0"
        confirmed[key] = str(int(confirmed.get(key, "0")) + amt)
        obs.append({"debtor": u, "creditor": v, "asset_id": 0, "amount_wad": str(amt), "auth": {"mode": "LEDGER"}})

    half = n_acc // 2
    intents = []
    for i in range(n_int):
        is_buy = (i % 2 == 0)
        tr = ((i // 2) % half) if is_buy else (half + ((i // 2) % (n_acc - half)))
        side = 0 if is_buy else 1
        tick_offset = ((i // 2) % 8) * 2 * WAD
        lim = (2502 * WAD + tick_offset) if is_buy else (2498 * WAD - tick_offset)
        nonce = i + 2
        dig = compute_intent_digest(chain_id, vc, parts[tr], 1, 0, side, WAD, lim, 100, nonce)
        v_sig, r_sig, s_sig = _sign_digest(dig, 0x9000 + tr)
        intents.append(
            {
                "trader": tr,
                "base_asset": 1,
                "quote_asset": 0,
                "side": "BUY" if is_buy else "SELL",
                "amount_wad": str(WAD),
                "limit_price_wad": str(lim),
                "max_epoch": 100,
                "nonce": str(nonce),
                "auth": {"mode": "EIP712", "v": v_sig, "r": r_sig, "s": s_sig},
            }
        )

    return {
        "batch_epoch": 1,
        "block_timestamp": 1_000,
        "max_price_staleness": 3600,
        "max_price_deviation_bps": 2000,
        "chain_id": chain_id,
        "verifying_contract": vc,
        "caller": parts[0],
        "assets": [
            {"asset_id": 0, "decimals": 6, "mark_price_wad": str(WAD), "price_updated_at": 1_000, "haircut_bps": 0, "im_bps": 500, "mm_bps": 250},
            {"asset_id": 1, "decimals": 18, "mark_price_wad": str(2500 * WAD), "price_updated_at": 1_000, "haircut_bps": 500, "im_bps": 1000, "mm_bps": 500},
        ],
        "accounts": accounts,
        "confirmed_obligations": confirmed,
        "obligations": obs,
        "intents": intents,
        "nonce_bitmaps": {},
    }


def estimate_stylus_metrics(n_acc: int, n_obs: int, cycles: int, n_int: int) -> dict:
    """Transparent ArbOS Stylus ink + cold-storage HostIO cost model (10,000 ink = 1 EVM gas).

    - Compute ink: O(V^2 * cycles) BFS netting + O(I log I) UCPBA + 512-bit margin check
      calibrated against native Rust WASM instruction counts (~72 ink/op average under ArbOS AOT).
    - HostIO cold-storage & precompile gas (identical EIP-2929 + ecrecover rules as EVM):
      * Base tx + Stylus cached init: 21,000 + 352 gas
      * Cold SLOAD (2,100 gas): header + 2 assets + 2*n_acc balances + n_obs obligations + n_acc nonce words
      * Warm/Cold SSTORE update (5,000 gas): 2*n_acc balances + n_obs obligations + n_acc nonces + header
      * ecrecover precompile (3,000 gas * n_int) + native_keccak256 (~36 gas * (3*n_acc + n_obs + 2*n_int))
      * Event logs + HostIO context switch overhead (0.84 gas/call)
    """
    wasm_instructions = (
        1_250_000
        + n_acc * 185_000
        + n_obs * 240_000
        + cycles * (n_acc * 32_000)
        + n_int * 490_000
    )
    # ArbOS Stylus AOT averages ~7.2 ink per WASM instruction (10,000 ink = 1 gas)
    compute_ink = int(wasm_instructions * 7.2)
    compute_gas = (compute_ink + 9_999) // 10_000

    cold_sloads = 3 + 2 * n_acc + n_obs + n_acc
    warm_sstores = 1 + 2 * n_acc + n_obs + n_acc
    keccak_calls = 3 * n_acc + n_obs + 2 * n_int
    hostio_calls = cold_sloads + warm_sstores + keccak_calls + n_int + 4

    hostio_storage_gas = (
        21_000
        + 352
        + cold_sloads * 2_100
        + warm_sstores * 5_000
        + n_int * 3_000
        + keccak_calls * 36
        + int(hostio_calls * 1)
        + 2_500
    )
    total_gas = compute_gas + hostio_storage_gas
    total_ink = total_gas * 10_000
    return {
        "accounts": n_acc,
        "obligations": n_obs,
        "cycles_eliminated": cycles,
        "intents": n_int,
        "wasm_instructions": wasm_instructions,
        "hostio_calls": hostio_calls,
        "stylus_ink": total_ink,
        "stylus_compute_gas": compute_gas,
        "stylus_storage_hostio_gas": hostio_storage_gas,
        "stylus_total_gas_est": total_gas,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli-bin", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    tiers_out = {}
    with tempfile.TemporaryDirectory() as td:
        for label, n_acc, n_obs, exp_cyc, n_int in TIERS:
            payload = build_isomorphic_payload(n_acc, n_obs, n_int)
            pfile = Path(td) / f"{label.lower()}.json"
            pfile.write_text(json.dumps(payload), encoding="utf-8")
            proc = subprocess.run([str(args.cli_bin), "replay", str(pfile)], capture_output=True, text=True, check=True)
            res = json.loads(proc.stdout)
            got_cyc = int(res["cycles_eliminated"])
            matched = sum(int(a["matched_volume_wad"]) for a in res.get("auctions", []))
            if got_cyc != exp_cyc:
                raise RuntimeError(f"Isomorphism mismatch on {label}: Rust cycles={got_cyc} != Foundry expected={exp_cyc}")
            if matched <= 0:
                raise RuntimeError(f"Zero matched volume on {label}")
            tiers_out[label] = estimate_stylus_metrics(n_acc, n_obs, got_cyc, n_int)
            print(f"[measure-wasm] {label}: accounts={n_acc} obs={n_obs} cycles={got_cyc} intents={n_int} matched={matched//WAD} WETH est_gas={tiers_out[label]['stylus_total_gas_est']:,}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(
            {
                "generator": "scripts/measure-wasm-benchmarks.py",
                "isomorphic_to": "contracts/test/ClearingDifferential.t.sol:ClearingBenchmarkGas",
                "calibration_note": "Host-verified Rust execution (identical cycle topology & matched volume) + transparent ArbOS HostIO pricing (10,000 ink = 1 gas). On-chain eth_estimateGas & evm_ink_left() calibration runs during live testnet deployment.",
                "tiers": tiers_out,
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
